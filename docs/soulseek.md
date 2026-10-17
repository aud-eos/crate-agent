# Soulseek acquisition (Phase 1)

Drive Soulseek downloads from a tracklist via Claude, routed through a local [slskd](https://github.com/slskd/slskd) daemon. The official SoulseekQt desktop app has no API and is not used here — slskd is the headless, REST-driven daemon that exposes Soulseek over HTTP.

## How it works

`soulseek-mcp` is a standalone MCP binary. When registered with Claude, it exposes six tools:

| Tool | What it does |
|------|-------------|
| `ingest_list` | Parse a newline-delimited `Artist - Title` list into a session |
| `plan_acquisition` | Search slskd; auto-accepted entries are enqueued immediately, proposed entries await `confirm_download`, parked entries need manual attention |
| `review_candidates` | Show ranked candidates for one entry |
| `set_auto_accept` | Toggle high-confidence auto-accept and set the minimum score |
| `confirm_download` | Queue a chosen candidate for download in slskd |
| `acquisition_status` | Poll download progress; fingerprint + manifest finished files; report the needs-review list |

Typical flow: `ingest_list` → `plan_acquisition` (auto-accepted entries are enqueued here) → `review_candidates` / `confirm_download` for proposed entries → `acquisition_status` (poll until complete).

`acquisition_status` writes a `<filename>.json` manifest into the staging dir for each confirmed download. The manifest includes the Chromaprint fingerprint Phase 2 will use to identify the download (see [Phase 2 design](#phase-2-design)). Anything that cannot be confirmed (decode failure, duration mismatch, file not yet in staging dir) lands in the returned `needs_review` list.

## Phase 2 design

Phase 2 (issue #92, gated on Pillar C placeholder tracks) adds no new write path. A filesystem observation of a staged file plus its `AcquisitionRecord` produces one `FillPlaceholder` mutation through `OperationEngine`. Forward: link the file to the placeholder track, clear `is_placeholder`, move the file into its artist bucket (Invariant 5), and add it to Serato through the watchdog-guarded queue. Inverse: remove it from Serato, move it back to `staging/`, and set `is_placeholder` again. Writing crate-agent's SQLite or `_Serato_` files directly from `soulseek-core`/`soulseek-mcp` was rejected because it bypasses Invariants 1 and 3.

The join key needs redesign before implementation. The manifest stores the raw Chromaprint `fingerprint`, but `tracks.fingerprint_hash` is the exact SHA-256 of one file's fingerprint bytes and is `NOT NULL UNIQUE`. A placeholder has no audio, so it has no fingerprint, and a downloaded encode will not byte-match an existing one. Workable joins are an AcoustID lookup of the manifest fingerprint compared against the placeholder's `musicbrainz_recording_id`, or explicit confirmation. Placeholder rows also need a schema change to `fingerprint_hash`.

## Prerequisites

### slskd

`soulseek-mcp` talks to a running [slskd](https://github.com/slskd/slskd) instance. slskd holds your Soulseek credentials — they never touch crate-agent or Claude.

Install on macOS:

```sh
brew install slskd
# or download a release binary from https://github.com/slskd/slskd/releases
```

Configure `slskd.yml` with your Soulseek username, password, and an API key:

```yaml
web:
  authentication:
    api_keys:
      - key: "your-api-key-here"
        role: ReadWrite
```

Start slskd and verify it's reachable at `http://localhost:5030` (the default port).

### Environment variables

`soulseek-mcp` requires three env vars at startup — the binary panics fast if any is missing:

| Variable | Example | Purpose |
|----------|---------|---------|
| `SLSKD_URL` | `http://localhost:5030` | Base URL of the local slskd instance |
| `SLSKD_API_KEY` | `your-api-key-here` | API key from `slskd.yml` `web.authentication.api_keys` |
| `SOULSEEK_STAGING_DIR` | `/Users/you/Music/_staging` | Directory where completed downloads land and manifests are written. **Must match slskd's configured download directory** (`directories.downloads` in `slskd.yml`) — if these differ, `acquisition_status` cannot find completed files and every download falls to `needs_review`. |

## Build

```sh
cargo build --manifest-path rust-core/Cargo.toml -p soulseek-mcp --release
```

Binary: `rust-core/target/release/soulseek-mcp`

## Claude MCP registration

Add to your Claude MCP configuration (e.g. `~/.claude.json` `mcpServers` section):

```json
{
  "mcpServers": {
    "soulseek": {
      "command": "/absolute/path/to/rust-core/target/release/soulseek-mcp",
      "env": {
        "SLSKD_URL": "http://localhost:5030",
        "SLSKD_API_KEY": "<from slskd.yml>",
        "SOULSEEK_STAGING_DIR": "/Users/you/Music/_staging"
      }
    }
  }
}
```

Replace `/absolute/path/to/` with the actual path to your crate-agent repo.

## Manual smoke-test steps

A live end-to-end test requires a running slskd with an active Soulseek login. Run this after setup:

### 1. Build and start the MCP server

```sh
cargo build --manifest-path rust-core/Cargo.toml -p soulseek-mcp --release
SLSKD_URL=http://localhost:5030 \
SLSKD_API_KEY=your-key \
SOULSEEK_STAGING_DIR=~/Music/_staging \
  ./rust-core/target/release/soulseek-mcp
```

### 2. Run the flow via Claude

With the MCP server registered and Claude open:

1. **Ingest:** call `ingest_list` with a two-line list, e.g.:
   ```
   Daft Punk - Around the World
   Daft Punk - Harder Better Faster Stronger
   ```
   Note the `session_id` returned.

2. **Plan:** call `plan_acquisition` with that `session_id`. Claude will search slskd, immediately enqueue any auto-accepted entries, and report auto-accepted / proposed / parked counts.

3. **Confirm:** for any `proposed` entries, call `review_candidates` to see the ranked list, then `confirm_download` to queue your chosen candidate. For auto-accepted entries the top candidate is queued automatically.

4. **Verify in slskd UI:** open `http://localhost:5030` and confirm the transfers appear under Downloads.

5. **Poll until complete:** once slskd shows the transfers as complete, call `acquisition_status`. Expected successful outcome:
   - `completed` lists the finished filenames
   - `confirmed` lists the filenames that passed fingerprint verification
   - `needs_review` is empty (or lists only entries where the file is not yet present in `SOULSEEK_STAGING_DIR`)
   - A `<filename>.json` manifest with a non-empty `fingerprint` array appears in `SOULSEEK_STAGING_DIR` for each confirmed file

If `needs_review` is non-empty, the message explains why (file not in staging dir, decode failure, duration mismatch).
