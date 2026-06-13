# Soulseek Acquisition — Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pre-implementation
**Topic:** Drive Soulseek downloads from a list, as a shared Rust core consumed by both a Claude MCP server and (later) crate-agent.

## Problem

The user wants to download songs from a list via Soulseek, ideally driven through Claude, and ideally synced into crate-agent's library.

The official Soulseek app (SoulseekQt / classic client) has **no API, no plugin hooks, no scripting surface** — the same black-box wall Serato presents. Automating the GUI app directly is a dead end.

## Substrate decision: slskd

[`slskd`](https://github.com/slskd/slskd) is a modern, headless, self-hosted Soulseek **daemon**. Same network, same Soulseek logins, but it exposes a **token-secured REST API** for search, queue-download, progress-tracking, and webhooks. Runs natively on macOS (or Docker), binds to `127.0.0.1`.

**Everything we build is a consumer of slskd's REST API.** We never re-implement the Soulseek protocol. This is the same pattern crate-agent already uses with Serato: the consumer-facing app is a black box, so we route around it to a programmable substrate (Serato → `triseratops`; Soulseek → `slskd`).

Deployment: native macOS `slskd` instance, localhost-only, running as a background daemon.

## Shape: shared core, two consumers (decision C)

The only genuinely *shared* logic is the **selection intelligence**: turn one list entry into a search query, rank noisy candidate results, pick the best, queue it, and after download confirm it's really the right recording. slskd already owns the connection, search engine, and download queue — we do not re-implement any of that.

That selection logic lives **once**, in crate-agent's existing `rust-core/` (decision A), reachable by both consumers:
- **crate-agent** via the `uniffi` bridge it already has.
- **MCP server** as a thin shell (a small Rust binary built from the same crate, or a CLI it shells to).

The ranking logic — the part that determines whether the crate fills with gold or garbage — exists exactly once.

## The shared core: `rust-core/soulseek` module

Five units, each one job, each independently testable. I/O is isolated to two of them; the quality-critical logic is pure (and therefore trivially unit-testable against recorded result blobs).

| Unit | Job | I/O? | Depends on |
|------|-----|------|------------|
| `SlskdClient` | Typed wrapper over slskd's REST API (search, queue, poll, cancel). | **Yes** (HTTP) | slskd |
| `QueryBuilder` | Rich list-entry → search query string(s). **Pure.** | No | nothing |
| `CandidateRanker` | Noisy result set → scored, sorted candidates. **Pure — the brain.** | No | nothing |
| `AcquisitionPlanner` | Orchestrates search → rank → decide (propose / auto-accept / park). Holds the confidence policy. | No | the three above |
| `DownloadConfirmer` | Post-download: Chromaprint-fingerprint the file, confirm it matches the expected recording, write the staging manifest. | **Yes** (fs) | `chromaprint` (already in stack) |

**Design rationale — I/O isolation:** only `SlskdClient` and `DownloadConfirmer` touch the outside world. `QueryBuilder` and `CandidateRanker` are pure functions, so the hard-to-get-right logic is the easy-to-test logic: feed `CandidateRanker` a recorded JSON blob of real slskd results and assert the ranking — no network, no daemon. Mirrors the existing `ArtistLetterNormalizer` discipline (single-source-of-truth pure function).

## Data model

### `ListEntry` (the rich list entry — decision C)

Deliberately a subset of crate-agent's `tracks`/placeholder schema, so the two are the same object at different lifecycle stages (wishlist → acquire → fingerprint-confirm → placeholder filled).

```
ListEntry {
  artist, title                       // required — the query floor
  album?, year?                        // disambiguation hints
  duration_secs?                       // rejects radio edits / extended mixes by ±tolerance
  isrc?, musicbrainz_recording_id?     // strongest signal when present (from Pillar B/C)
  format_preference?                   // FLAC | "320+" | any  (feeds the quality gate)
}
```

### Input adapters (each ~30 lines, each producing `ListEntry`s)

- `text-paste` — `Artist – Title` lines (MCP's day-one input).
- `crate-agent-placeholders` — reads `is_placeholder = TRUE` rows (the bridge; enrichment free from MusicBrainz).
- *(later)* `spotify-export`, `m3u` — where Pillar D plugs in.

### `AcquisitionRecord` (the staging manifest — the handoff contract)

One JSON record per completed download, written next to the file in `staging/`.

```
AcquisitionRecord {
  list_entry          // what we were looking for
  file_path           // where it landed in staging/
  fingerprint_hash    // Chromaprint — THE join key to the placeholder
  source              // slskd user, original filename, bitrate, format, size
  confirmed           // did fingerprint match expected recording? (DownloadConfirmer's verdict)
}
```

**Design rationale — fingerprint as join key (Invariant #4):** crate-agent's reconciler matches download→placeholder by `fingerprint_hash`, **not** by filename (which Soulseek mangles constantly — `01_-_artist_-_title_FINAL.mp3`). A sloppily-named download still lands on the right placeholder; a *wrong* file (slskd handed us a mislabeled track) is caught because its fingerprint won't match any waiting entry. The manifest turns Soulseek's biggest weakness — unreliable filenames — into a non-issue.

## Download decision flow (decision C: both, as a setting)

Default **propose-then-confirm**, with a **high-confidence auto-accept** toggle.

- **Propose-then-confirm:** for each entry, the core searches, ranks, and presents the top-N candidates (format, bitrate, size, user slot status, filename) for a human — or Claude — to pick/approve before queuing. Keeps quality high.
- **Auto-accept (toggle):** auto-pick the best candidate that clears a hard quality gate (e.g. FLAC-or-≥320kbps, real free slot, filename matches artist+title, duration within ±tolerance). Anything that can't clear the gate falls to the **needs-review** list.

This maps onto crate-agent's event-log model (Invariant #2): a queued download is a *pending acquisition* with a forward action and a natural inverse; propose/confirm is just deferring the mutation commit until a human or a confidence threshold commits it — exactly how `SeratoWatchdog` already defers writes.

## Consumer surface 1 — MCP server (thin shell over the core)

| Tool | Does |
|------|------|
| `ingest_list` | text/paste/file → `ListEntry[]`, returns a session id |
| `plan_acquisition` | runs search+rank for the session; returns per-entry ranked candidates |
| `review_candidates` | shows the top-N for an entry (format/bitrate/slot/filename) for Claude to judge |
| `confirm_download` | commits a chosen candidate → queues in slskd |
| `acquisition_status` | poll queue progress + the parked / needs-review list |
| `set_auto_accept` | toggles the high-confidence auto policy + threshold |

Claude-in-the-loop is a genuine quality win here: Claude reads candidates and applies judgment ("that's a YouTube transcode, take the vinyl rip") before confirming.

## Consumer surface 2 — crate-agent (`SoulseekReconciler`)

crate-agent's **existing** FSEvents watcher sees a new file in `staging/`, reads its `AcquisitionRecord`, and emits **one new mutation type** — `FillPlaceholder { track_id, file_path, fingerprint_hash }` — through `OperationEngine.applyMutation`. **Zero new write paths.**

- **Forward:** link file → placeholder track, flip `is_placeholder` false, move into `<Letter>/` (Invariant #5), add to Serato.
- **Inverse (Invariant #2):** remove from Serato, move file back to `staging/`, re-set `is_placeholder` true.

**Design rationale — let the existing chokepoint do its job (Invariants #1–3):** an acquired download is just *another file appearing*, which is exactly what SP-1 already turns into a vetted mutation (the Finder-rename bug). The acquisition core stays strictly **outside** the `_Serato_` write path. Writing crate-agent's SQLite directly was explicitly rejected: it would violate Invariant #1 (all state changes go through `applyMutation`) and Invariant #3 (no `_Serato_` writes outside the running-state guard), silently corrupting the library when Serato is open.

## Sequencing: two phases

The crate-agent half depends on the **placeholder-track concept, which is Pillar C (SP-4+)** — it does not exist in today's SP-1 codebase. The acquisition core + MCP depend on *nothing* in crate-agent. So they cleave cleanly:

- **Phase 1 — ships now, standalone:** `rust-core/soulseek` (all 5 units) + the MCP server + `text-paste` adapter + downloads land in `staging/` with manifests. Fully useful alone: drive Soulseek from a list via Claude today. No crate-agent dependency. **This is the whole deliverable for now.**
- **Phase 2 — when Pillar C placeholders land:** the `crate-agent-placeholders` adapter + `SoulseekReconciler` + the `FillPlaceholder` mutation. The Phase 1 manifest contract is *already exactly* what Phase 2 consumes, so nothing built in Phase 1 gets reworked.

## Hard edges

- **Secrets:** slskd's API token and Soulseek credentials live in slskd's own config file the user writes — they never pass through Claude or the transcript. The core reads the token from an **env var asserted at startup** (strict-env-var rule; fail fast on misconfiguration).
- **Failures are loud:** a download that can't fingerprint-confirm does **not** silently drop — it lands in the parked/needs-review list surfaced by `acquisition_status` (a channel the user actually checks). No `log-and-continue`.
- **Testing:** `QueryBuilder` / `CandidateRanker` unit-tested against recorded real slskd result blobs; `SlskdClient` against a mock HTTP server; the reconciler is a Phase-2 concern.

## Out of scope

- Re-implementing the Soulseek protocol (slskd owns it).
- Automating the official SoulseekQt GUI (no API — the reason slskd exists).
- Spotify / m3u adapters (later; Pillar D).
- The crate-agent reconciler and `FillPlaceholder` mutation (Phase 2, gated on Pillar C).

## References

- [slskd — GitHub](https://github.com/slskd/slskd)
- [slskd — Headless Soulseek Client](https://slskd.com/)
- crate-agent Invariants #1–5, `CLAUDE.md`
- crate-agent `design-plan.md` — Pillar C (placeholder/wishlist tracks), Pillar D (external bridges)
