# Soulseek Acquisition — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a standalone Soulseek acquisition tool — driven by Claude via MCP — that takes a text list of songs, searches Soulseek through a local `slskd` daemon, ranks the noisy candidates, downloads chosen tracks, and verifies + fingerprints them into a `staging/` folder with a per-download manifest.

**Architecture:** A new `soulseek-core` Rust library holds the selection intelligence (query-building, candidate ranking, the propose/auto-accept policy, download confirmation). The only I/O units are `SlskdClient` (HTTP to slskd) and `DownloadConfirmer` (filesystem + audio decode); the quality-critical ranking logic is pure and unit-tested against recorded result blobs. A thin `soulseek-mcp` binary (official `rmcp` SDK, stdio transport) exposes the core to Claude. The Chromaprint decode that `crate-agent-core` already owns is extracted into a shared `fingerprint-core` crate so it is implemented once. Phase 2 (the crate-agent reconciler + `FillPlaceholder` mutation, gated on Pillar C placeholders) is **out of scope**.

**Tech Stack:** Rust (Cargo workspace), `reqwest` (async HTTP), `tokio`, `rmcp` (MCP SDK), `rusty-chromaprint` + `symphonia` (decode, via `fingerprint-core`), `lofty` (audio properties), `serde`/`serde_json`, `thiserror`; `wiremock` for HTTP tests.

**Spec:** `docs/superpowers/specs/2026-06-12-soulseek-acquisition-design.md`

**A note on the red-state stubs below:** TDD steps need a body that compiles but fails the test. These use `panic!("stub")` as that body; the very next step in the same task replaces it with the real implementation. They are not deferred work — each is resolved before its task ends.

---

## File Structure

All new code lives under the existing `rust-core/` directory, which becomes a Cargo workspace root. `crate-agent-core` stays exactly where it is (package root at `rust-core/`, which doubles as the workspace root) so the Swift build paths in `scripts/build-rust.sh`, `Makefile`, and `project.yml` keep working.

```
rust-core/
  Cargo.toml                      # MODIFY: add [workspace] table
  build.rs                        # unchanged (crate-agent-core)
  src/                            # crate-agent-core sources
    crate-agent-core.udl          # unchanged
    lib.rs                        # MODIFY: drop `mod fingerprint;`
    ffi.rs                        # MODIFY: import fingerprint from new crate
    serato.rs  tags.rs            # unchanged
    bin/uniffi-bindgen.rs         # unchanged
    fingerprint.rs                # DELETE (moves to fingerprint-core)
  fingerprint-core/               # NEW lib crate — the shared decode mechanic
    Cargo.toml
    src/lib.rs                    # moved verbatim from src/fingerprint.rs
  soulseek-core/                  # NEW lib crate — the selection intelligence
    Cargo.toml
    src/
      lib.rs                      # module wiring + re-exports
      types.rs                    # ListEntry, Candidate, ScoredCandidate, AcquisitionRecord, …
      error.rs                    # SoulseekError
      query_builder.rs            # build_query (pure)
      candidate_ranker.rs         # rank (pure — the brain)
      planner.rs                  # ConfidencePolicy, Decision, decide (pure) + plan (async)
      slskd_client.rs             # SlskdClient (async HTTP — the only network I/O)
      confirmer.rs                # confirm_download (decode + fingerprint verdict)
      staging.rs                  # write_manifest / read_manifest
      adapters/
        mod.rs
        text_paste.rs             # parse_text → entries + skipped lines
  soulseek-mcp/                   # NEW binary crate — thin MCP shell over soulseek-core
    Cargo.toml
    src/main.rs                   # rmcp stdio server + 6 tool handlers
scripts/build-rust.sh             # MODIFY: scope cargo to -p crate-agent-core
docs/soulseek.md                  # NEW: slskd setup + MCP usage doc
README.md                         # MODIFY: add Soulseek acquisition section
```

**Decomposition rationale:** I/O is quarantined to `slskd_client.rs` and `confirmer.rs`. `query_builder.rs`, `candidate_ranker.rs`, and `planner.rs::decide` are pure functions — the parts whose correctness determines crate quality are the parts that test with zero network and zero daemon.

---

## Task 0: Workspace + extract `fingerprint-core` (refactor, keep existing tests green)

**Files:**
- Modify: `rust-core/Cargo.toml`
- Create: `rust-core/fingerprint-core/Cargo.toml`
- Create: `rust-core/fingerprint-core/src/lib.rs` (moved from `rust-core/src/fingerprint.rs`)
- Delete: `rust-core/src/fingerprint.rs`
- Modify: `rust-core/src/lib.rs`, `rust-core/src/ffi.rs`
- Modify: `scripts/build-rust.sh`

- [ ] **Step 1: Capture the green baseline**

Run: `make test-rust`
Expected: existing Rust tests PASS. Record the count — it must not drop after this task.

- [ ] **Step 2: Create the `fingerprint-core` crate manifest**

Create `rust-core/fingerprint-core/Cargo.toml`:

```toml
[package]
name = "fingerprint-core"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
rusty-chromaprint = "0.3"
symphonia = { version = "0.6", features = ["mp3", "aac", "alac", "isomp4", "aiff"] }
thiserror = "1"
```

- [ ] **Step 3: Move the fingerprint source verbatim**

Move `rust-core/src/fingerprint.rs` → `rust-core/fingerprint-core/src/lib.rs` with **no content changes** (it already exposes `pub fn fingerprint_file`, `pub const FINGERPRINT_MAX_DURATION_SECONDS`, `pub enum FingerprintError`, and its `#[cfg(test)] mod tests`).

```bash
mkdir -p rust-core/fingerprint-core/src
git mv rust-core/src/fingerprint.rs rust-core/fingerprint-core/src/lib.rs
```

- [ ] **Step 4: Turn `rust-core/Cargo.toml` into a workspace root and drop the moved deps**

In `rust-core/Cargo.toml`, add a workspace table at the top (above `[package]`):

```toml
[workspace]
members = ["fingerprint-core", "soulseek-core", "soulseek-mcp"]
resolver = "2"
```

Then, in the same file, **remove** the `rusty-chromaprint` and `symphonia` dependency lines (they now live in `fingerprint-core`) and **add** a path dependency:

```toml
fingerprint-core = { path = "fingerprint-core" }
```

Leave `lofty`, `serde`, `serde_json`, `thiserror`, `uniffi` as they are.

- [ ] **Step 5: Re-point `crate-agent-core` at the new crate**

In `rust-core/src/lib.rs`, delete the line `mod fingerprint;`.

In `rust-core/src/ffi.rs`, change the import line `use crate::fingerprint;` to:

```rust
use fingerprint_core as fingerprint;
```

This keeps every existing `fingerprint::fingerprint_file(...)` call and the `From<fingerprint::FingerprintError> for CoreError` impl resolving unchanged.

- [ ] **Step 6: Verify the refactor compiles and existing tests still pass**

Run: `cargo build --manifest-path rust-core/Cargo.toml -p crate-agent-core`
Expected: builds clean. If the compiler reports `symphonia`/`rusty-chromaprint` used elsewhere in `crate-agent-core`, that usage must move to `fingerprint-core` too (it should not — only `fingerprint.rs` used them).

Run: `make test-rust`
Expected: same test count as Step 1, all PASS (fingerprint tests now run from `fingerprint-core`).

- [ ] **Step 7: Keep the Swift static-lib build scoped to one crate**

In `scripts/build-rust.sh`, change both `cargo build` invocations and the `uniffi-bindgen` run so the workspace's new members are NOT pulled into the Swift static library:

```bash
# the two target builds:
(cd "$RUST_DIR" && cargo build $CARGO_FLAGS -p crate-agent-core --target aarch64-apple-darwin)
(cd "$RUST_DIR" && cargo build $CARGO_FLAGS -p crate-agent-core --target x86_64-apple-darwin)

# the bindgen run:
(cd "$RUST_DIR" && cargo run $CARGO_FLAGS -p crate-agent-core --bin uniffi-bindgen -- \
    generate src/crate-agent-core.udl --language swift --out-dir "$SWIFT_GENERATED_DIR")
```

- [ ] **Step 8: Verify the universal static lib still builds**

Run: `make build-rust`
Expected: `build-output/libcrate_agent_core.a` produced; Swift bindings regenerated; no `soulseek-*` or `tokio` symbols dragged in (they aren't compiled by `-p crate-agent-core`).

- [ ] **Step 9: Commit**

```bash
git add rust-core/Cargo.toml rust-core/fingerprint-core rust-core/src/lib.rs rust-core/src/ffi.rs scripts/build-rust.sh
git commit -m "refactor(rust): extract fingerprint-core crate, make rust-core a workspace"
```

---

## Task 1: `soulseek-core` skeleton, types, and error

**Files:**
- Create: `rust-core/soulseek-core/Cargo.toml`
- Create: `rust-core/soulseek-core/src/lib.rs`
- Create: `rust-core/soulseek-core/src/error.rs`
- Create: `rust-core/soulseek-core/src/types.rs`
- Create: empty module files for the units implemented in later tasks

- [ ] **Step 1: Create the crate manifest**

Create `rust-core/soulseek-core/Cargo.toml`:

```toml
[package]
name = "soulseek-core"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "1"
reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls"] }
tokio = { version = "1", features = ["rt", "macros", "time"] }
lofty = "0.24"
fingerprint-core = { path = "../fingerprint-core" }

[dev-dependencies]
wiremock = "0.6"
tokio = { version = "1", features = ["rt", "macros", "time", "rt-multi-thread"] }
hound = "3"   # synthetic WAV generation in confirmer tests
```

- [ ] **Step 2: Define the error type**

Create `rust-core/soulseek-core/src/error.rs`:

```rust
use thiserror::Error;

/// Every fallible path in soulseek-core surfaces through this type.
/// No variant is a silent no-op — callers (MCP tools) map these into
/// the parked / needs-review surface rather than swallowing them.
#[derive(Debug, Error)]
pub enum SoulseekError {
    #[error("slskd request failed: {0}")]
    Slskd(String),
    #[error("slskd returned unexpected response: {0}")]
    SlskdProtocol(String),
    #[error("missing required configuration: {0}")]
    Config(String),
    #[error("download verification failed: {0}")]
    Confirm(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, SoulseekError>;
```

- [ ] **Step 3: Define the domain types**

Create `rust-core/soulseek-core/src/types.rs`:

```rust
use serde::{Deserialize, Serialize};

/// Desired output format for an entry. Feeds the ranker and the
/// auto-accept quality gate. Defaults to `Any`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum FormatPreference {
    Flac,
    /// Lossy, but at least 320 kbps.
    Lossy320Plus,
    #[default]
    Any,
}

/// One wanted track. A subset of crate-agent's track/placeholder schema
/// so the two are the same object at different lifecycle stages.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListEntry {
    pub artist: String,
    pub title: String,
    #[serde(default)]
    pub album: Option<String>,
    #[serde(default)]
    pub year: Option<u32>,
    #[serde(default)]
    pub duration_secs: Option<u64>,
    #[serde(default)]
    pub isrc: Option<String>,
    #[serde(default)]
    pub musicbrainz_recording_id: Option<String>,
    #[serde(default)]
    pub format_preference: FormatPreference,
}

/// One raw search result from slskd, normalized.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate {
    pub username: String,
    /// Remote path exactly as slskd reports it (often mangled:
    /// `01_-_artist_-_title_FINAL.mp3`).
    pub filename: String,
    pub size_bytes: u64,
    pub bitrate_kbps: Option<u32>,
    /// Lowercase extension without the dot: "flac", "mp3", "aiff".
    pub format: String,
    pub has_free_upload_slot: bool,
    pub length_secs: Option<u64>,
}

/// A candidate plus the ranker's verdict.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScoredCandidate {
    pub candidate: Candidate,
    pub score: i64,
    /// Human/Claude-readable notes on what helped or hurt the score.
    pub notes: Vec<String>,
}

/// Where a downloaded file came from. Recorded in the manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceInfo {
    pub slskd_username: String,
    pub original_filename: String,
    pub bitrate_kbps: Option<u32>,
    pub format: String,
    pub size_bytes: u64,
}

/// The staging-folder handoff contract — one per completed download.
/// `fingerprint` is the join key Phase 2 / crate-agent uses to match a
/// download to a waiting placeholder (by perceptual hash, NOT filename).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AcquisitionRecord {
    pub list_entry: ListEntry,
    pub file_path: String,
    pub fingerprint: Vec<u32>,
    pub source: SourceInfo,
    pub confirmed: bool,
}
```

- [ ] **Step 4: Wire the modules**

Create `rust-core/soulseek-core/src/lib.rs`:

```rust
pub mod adapters;
pub mod candidate_ranker;
pub mod confirmer;
pub mod error;
pub mod planner;
pub mod query_builder;
pub mod slskd_client;
pub mod staging;
pub mod types;

pub use error::{Result, SoulseekError};
pub use types::*;
```

The unit modules are implemented in their own tasks below. Create them now as valid empty modules (a comment-only file is a valid Rust module, so `lib.rs` compiles immediately):

```bash
mkdir -p rust-core/soulseek-core/src/adapters
printf '%s\n' '// candidate ranker — implemented in Task 4' > rust-core/soulseek-core/src/candidate_ranker.rs
printf '%s\n' '// download confirmer — implemented in Task 7'  > rust-core/soulseek-core/src/confirmer.rs
printf '%s\n' '// acquisition planner — implemented in Task 6' > rust-core/soulseek-core/src/planner.rs
printf '%s\n' '// query builder — implemented in Task 3'       > rust-core/soulseek-core/src/query_builder.rs
printf '%s\n' '// slskd client — implemented in Task 5'        > rust-core/soulseek-core/src/slskd_client.rs
printf '%s\n' '// staging manifest — implemented in Task 7'    > rust-core/soulseek-core/src/staging.rs
printf '%s\n' 'pub mod text_paste;'                            > rust-core/soulseek-core/src/adapters/mod.rs
printf '%s\n' '// text-paste adapter — implemented in Task 2'  > rust-core/soulseek-core/src/adapters/text_paste.rs
```

- [ ] **Step 5: Verify the crate compiles**

Run: `cargo build --manifest-path rust-core/Cargo.toml -p soulseek-core`
Expected: builds clean (empty modules compile).

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core`
Expected: 0 tests, PASS.

- [ ] **Step 6: Commit**

```bash
git add rust-core/soulseek-core
git commit -m "feat(soulseek-core): crate skeleton, domain types, error type"
```

---

## Task 2: `text-paste` input adapter

**Files:**
- Modify: `rust-core/soulseek-core/src/adapters/text_paste.rs`

- [ ] **Step 1: Write the failing tests**

Replace `rust-core/soulseek-core/src/adapters/text_paste.rs` with:

```rust
use crate::types::ListEntry;

/// Result of parsing a pasted list. `skipped` carries every line we
/// could not parse — surfaced loudly to the caller, never dropped.
#[derive(Debug, PartialEq, Eq)]
pub struct ParseResult {
    pub entries: Vec<ListEntry>,
    pub skipped: Vec<String>,
}

/// Parse a newline-delimited `Artist - Title` (or `Artist – Title`,
/// en-dash) list. Blank/whitespace-only lines are ignored. Lines with
/// no recognized separator go to `skipped`.
pub fn parse_text(input: &str) -> ParseResult {
    panic!("stub")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(artist: &str, title: &str) -> ListEntry {
        ListEntry {
            artist: artist.to_string(),
            title: title.to_string(),
            album: None,
            year: None,
            duration_secs: None,
            isrc: None,
            musicbrainz_recording_id: None,
            format_preference: Default::default(),
        }
    }

    #[test]
    fn parses_hyphen_and_endash_separators() {
        let result = parse_text("Daft Punk - Around the World\nSigur Rós – Hoppípolla");
        assert_eq!(result.entries, vec![
            entry("Daft Punk", "Around the World"),
            entry("Sigur Rós", "Hoppípolla"),
        ]);
        assert!(result.skipped.is_empty());
    }

    #[test]
    fn trims_whitespace_and_ignores_blank_lines() {
        let result = parse_text("  Aphex Twin  -  Xtal  \n\n   \n");
        assert_eq!(result.entries, vec![entry("Aphex Twin", "Xtal")]);
        assert!(result.skipped.is_empty());
    }

    #[test]
    fn splits_on_first_separator_only() {
        let result = parse_text("Tyler, The Creator - See You Again - feat. Kali Uchis");
        assert_eq!(result.entries, vec![
            entry("Tyler, The Creator", "See You Again - feat. Kali Uchis"),
        ]);
    }

    #[test]
    fn collects_unparseable_lines_into_skipped() {
        let result = parse_text("Just A Title With No Separator");
        assert!(result.entries.is_empty());
        assert_eq!(result.skipped, vec!["Just A Title With No Separator".to_string()]);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core text_paste`
Expected: FAIL (panic: stub).

- [ ] **Step 3: Implement `parse_text`**

Replace the `panic!("stub")` body:

```rust
pub fn parse_text(input: &str) -> ParseResult {
    const SEPARATORS: [&str; 2] = [" - ", " – "]; // hyphen, en-dash

    let mut entries = Vec::new();
    let mut skipped = Vec::new();

    for raw_line in input.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        let split = SEPARATORS
            .iter()
            .filter_map(|separator| line.find(separator).map(|index| (index, separator.len())))
            .min_by_key(|(index, _)| *index);

        match split {
            Some((index, separator_len)) => {
                let artist = line[..index].trim().to_string();
                let title = line[index + separator_len..].trim().to_string();
                if artist.is_empty() || title.is_empty() {
                    skipped.push(line.to_string());
                } else {
                    entries.push(ListEntry {
                        artist,
                        title,
                        album: None,
                        year: None,
                        duration_secs: None,
                        isrc: None,
                        musicbrainz_recording_id: None,
                        format_preference: Default::default(),
                    });
                }
            }
            None => skipped.push(line.to_string()),
        }
    }

    ParseResult { entries, skipped }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core text_paste`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add rust-core/soulseek-core/src/adapters/text_paste.rs
git commit -m "feat(soulseek-core): text-paste list adapter"
```

---

## Task 3: `QueryBuilder`

**Files:**
- Modify: `rust-core/soulseek-core/src/query_builder.rs`

- [ ] **Step 1: Write the failing tests**

Replace `rust-core/soulseek-core/src/query_builder.rs` with:

```rust
use crate::types::ListEntry;

/// Build a Soulseek search string from a list entry. slskd matches the
/// space-separated terms against shared filenames, so we reduce artist
/// and title to lowercased alphanumeric tokens (punctuation that would
/// fragment matches is dropped) and join them with single spaces.
pub fn build_query(entry: &ListEntry) -> String {
    panic!("stub")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(artist: &str, title: &str) -> ListEntry {
        ListEntry {
            artist: artist.to_string(),
            title: title.to_string(),
            album: None,
            year: None,
            duration_secs: None,
            isrc: None,
            musicbrainz_recording_id: None,
            format_preference: Default::default(),
        }
    }

    #[test]
    fn lowercases_and_joins_artist_and_title() {
        assert_eq!(build_query(&entry("Daft Punk", "Around the World")),
                   "daft punk around the world");
    }

    #[test]
    fn strips_punctuation_that_fragments_matching() {
        assert_eq!(build_query(&entry("Tyler, The Creator", "See You Again (feat. Kali Uchis)")),
                   "tyler the creator see you again feat kali uchis");
    }

    #[test]
    fn preserves_unicode_letters_and_digits() {
        assert_eq!(build_query(&entry("Sigur Rós", "Festival 2")),
                   "sigur rós festival 2");
    }

    #[test]
    fn collapses_repeated_whitespace() {
        assert_eq!(build_query(&entry("A   B", "C  -  D")), "a b c d");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core query_builder`
Expected: FAIL (panic: stub).

- [ ] **Step 3: Implement `build_query`**

```rust
pub fn build_query(entry: &ListEntry) -> String {
    fn tokenize(text: &str) -> String {
        text.chars()
            .map(|character| if character.is_alphanumeric() { character } else { ' ' })
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
    }

    let combined = format!("{} {}", tokenize(&entry.artist), tokenize(&entry.title));
    combined.split_whitespace().collect::<Vec<_>>().join(" ")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core query_builder`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add rust-core/soulseek-core/src/query_builder.rs
git commit -m "feat(soulseek-core): query builder"
```

---

## Task 4: `CandidateRanker` (the brain)

**Files:**
- Modify: `rust-core/soulseek-core/src/candidate_ranker.rs`

- [ ] **Step 1: Write the failing tests**

Replace `rust-core/soulseek-core/src/candidate_ranker.rs` with:

```rust
use crate::types::{Candidate, FormatPreference, ListEntry, ScoredCandidate};

/// Score weights. Public so the planner's auto-accept gate can reason
/// about the same numbers the ranker produced.
pub const SCORE_FREE_SLOT: i64 = 40;
pub const SCORE_FLAC: i64 = 50;
pub const SCORE_LOSSY_PER_KBPS_OVER_128: i64 = 1; // 320 → +192
pub const SCORE_FILENAME_HAS_ARTIST: i64 = 25;
pub const SCORE_FILENAME_HAS_TITLE: i64 = 25;
pub const PENALTY_FORMAT_PREFERENCE_MISS: i64 = -200;
pub const PENALTY_PER_SECOND_DURATION_DRIFT: i64 = -4;
pub const DURATION_FREE_TOLERANCE_SECS: u64 = 5;

/// Rank candidates best-first for a wanted entry. Pure: same inputs →
/// same ordering, no I/O. Each candidate carries `notes` explaining the
/// score so a human or Claude can audit the ranking.
pub fn rank(entry: &ListEntry, candidates: &[Candidate]) -> Vec<ScoredCandidate> {
    panic!("stub")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_entry() -> ListEntry {
        ListEntry {
            artist: "Daft Punk".into(),
            title: "Around the World".into(),
            album: None, year: None, duration_secs: Some(429),
            isrc: None, musicbrainz_recording_id: None,
            format_preference: FormatPreference::Any,
        }
    }

    fn candidate(filename: &str, format: &str, bitrate: Option<u32>, slot: bool, length: Option<u64>) -> Candidate {
        Candidate {
            username: "someuser".into(),
            filename: filename.into(),
            size_bytes: 10_000_000,
            bitrate_kbps: bitrate,
            format: format.into(),
            has_free_upload_slot: slot,
            length_secs: length,
        }
    }

    #[test]
    fn flac_with_free_slot_and_matching_name_outranks_low_bitrate_transcode() {
        let entry = base_entry();
        let flac = candidate("Daft Punk - Around the World.flac", "flac", None, true, Some(429));
        let mp3_128 = candidate("around_the_world_YT_rip.mp3", "mp3", Some(128), true, Some(210));
        let ranked = rank(&entry, &[mp3_128.clone(), flac.clone()]);
        assert_eq!(ranked[0].candidate, flac);
        assert!(ranked[0].score > ranked[1].score);
    }

    #[test]
    fn duration_drift_is_penalized_against_radio_edit() {
        let entry = base_entry(); // wants 429s
        let full = candidate("Daft Punk - Around the World.mp3", "mp3", Some(320), true, Some(429));
        let radio = candidate("Daft Punk - Around the World (Radio).mp3", "mp3", Some(320), true, Some(210));
        let ranked = rank(&entry, &[radio, full.clone()]);
        assert_eq!(ranked[0].candidate, full);
    }

    #[test]
    fn flac_preference_disqualifies_non_flac() {
        let mut entry = base_entry();
        entry.format_preference = FormatPreference::Flac;
        let flac = candidate("x - y.flac", "flac", None, true, Some(429));
        let mp3 = candidate("x - y.mp3", "mp3", Some(320), true, Some(429));
        let ranked = rank(&entry, &[mp3, flac.clone()]);
        assert_eq!(ranked[0].candidate, flac);
        assert!(ranked[1].score < 0, "non-flac under FLAC preference must be penalized below zero");
    }

    #[test]
    fn no_free_slot_loses_the_slot_bonus() {
        let entry = base_entry();
        let with_slot = candidate("Daft Punk - Around the World.mp3", "mp3", Some(320), true, Some(429));
        let no_slot = candidate("Daft Punk - Around the World.mp3", "mp3", Some(320), false, Some(429));
        let ranked = rank(&entry, &[no_slot, with_slot.clone()]);
        assert_eq!(ranked[0].candidate, with_slot);
        assert_eq!(ranked[0].score - ranked[1].score, SCORE_FREE_SLOT);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core candidate_ranker`
Expected: FAIL (panic: stub).

- [ ] **Step 3: Implement `rank`**

```rust
pub fn rank(entry: &ListEntry, candidates: &[Candidate]) -> Vec<ScoredCandidate> {
    let mut scored: Vec<ScoredCandidate> =
        candidates.iter().map(|candidate| score_one(entry, candidate)).collect();
    // Best score first; ties broken by larger size (usually higher quality).
    scored.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then(right.candidate.size_bytes.cmp(&left.candidate.size_bytes))
    });
    scored
}

fn score_one(entry: &ListEntry, candidate: &Candidate) -> ScoredCandidate {
    let mut score = 0i64;
    let mut notes = Vec::new();
    let is_flac = candidate.format.eq_ignore_ascii_case("flac");

    if candidate.has_free_upload_slot {
        score += SCORE_FREE_SLOT;
        notes.push("free upload slot".into());
    } else {
        notes.push("no free slot (queued)".into());
    }

    if is_flac {
        score += SCORE_FLAC;
        notes.push("FLAC (lossless)".into());
    } else if let Some(bitrate) = candidate.bitrate_kbps {
        let over = (bitrate as i64 - 128).max(0);
        score += over * SCORE_LOSSY_PER_KBPS_OVER_128;
        notes.push(format!("{bitrate} kbps"));
    } else {
        notes.push("unknown bitrate".into());
    }

    match entry.format_preference {
        FormatPreference::Flac if !is_flac => {
            score += PENALTY_FORMAT_PREFERENCE_MISS;
            notes.push("does not meet FLAC preference".into());
        }
        FormatPreference::Lossy320Plus
            if !is_flac && candidate.bitrate_kbps.unwrap_or(0) < 320 =>
        {
            score += PENALTY_FORMAT_PREFERENCE_MISS;
            notes.push("below 320 kbps preference".into());
        }
        _ => {}
    }

    let haystack = candidate.filename.to_lowercase();
    let tokens_present = |text: &str| {
        text.to_lowercase()
            .split_whitespace()
            .all(|token| haystack.contains(token))
    };
    if tokens_present(&entry.artist) {
        score += SCORE_FILENAME_HAS_ARTIST;
        notes.push("filename contains artist".into());
    }
    if tokens_present(&entry.title) {
        score += SCORE_FILENAME_HAS_TITLE;
        notes.push("filename contains title".into());
    }

    if let (Some(want), Some(have)) = (entry.duration_secs, candidate.length_secs) {
        let drift = want.abs_diff(have);
        if drift > DURATION_FREE_TOLERANCE_SECS {
            let penalized = (drift - DURATION_FREE_TOLERANCE_SECS) as i64;
            score += penalized * PENALTY_PER_SECOND_DURATION_DRIFT;
            notes.push(format!("duration off by {drift}s"));
        }
    }

    ScoredCandidate { candidate: candidate.clone(), score, notes }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core candidate_ranker`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add rust-core/soulseek-core/src/candidate_ranker.rs
git commit -m "feat(soulseek-core): candidate ranker"
```

---

## Task 5: `SlskdClient` (async HTTP — the only network unit)

**Files:**
- Modify: `rust-core/soulseek-core/src/slskd_client.rs`

slskd's REST surface used here (verify shapes against the local slskd Swagger UI at `http://localhost:5030/swagger` when wiring real calls; the tests below pin our mapped contract regardless):
- `POST /api/v0/searches` with `{ "searchText": "<query>" }` → `{ "id": "<uuid>", ... }`
- `GET /api/v0/searches/{id}/responses` → array of responses, each `{ "username", "hasFreeUploadSlot", "files": [ { "filename", "size", "bitRate", "length", "extension" } ] }`
- `POST /api/v0/transfers/downloads/{username}` with `[ { "filename", "size" } ]` → 201
- `GET /api/v0/transfers/downloads` → per-user transfer state with `state` strings (e.g. `"Completed, Succeeded"`)

Auth: header `X-API-Key: <token>`.

- [ ] **Step 1: Write the failing tests (wiremock)**

Replace `rust-core/soulseek-core/src/slskd_client.rs` with the type + a test module:

```rust
use serde::Deserialize;

use crate::error::{Result, SoulseekError};
use crate::types::Candidate;

/// Thin typed wrapper over slskd's REST API. The ONLY unit in
/// soulseek-core that performs network I/O.
#[derive(Clone)]
pub struct SlskdClient {
    base_url: String,
    api_key: String,
    http: reqwest::Client,
}

#[derive(Debug, Deserialize)]
struct SearchCreated {
    id: String,
}

#[derive(Debug, Deserialize)]
struct SearchResponse {
    username: String,
    #[serde(rename = "hasFreeUploadSlot")]
    has_free_upload_slot: bool,
    files: Vec<SearchFile>,
}

#[derive(Debug, Deserialize)]
struct SearchFile {
    filename: String,
    size: u64,
    #[serde(rename = "bitRate")]
    bit_rate: Option<u32>,
    length: Option<u64>,
    extension: Option<String>,
}

impl SlskdClient {
    pub fn new(base_url: impl Into<String>, api_key: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            api_key: api_key.into(),
            http: reqwest::Client::new(),
        }
    }

    /// Initiate a search and return its slskd id.
    pub async fn start_search(&self, query: &str) -> Result<String> {
        panic!("stub")
    }

    /// Fetch the current responses for a search and normalize them to
    /// `Candidate`s.
    pub async fn fetch_results(&self, search_id: &str) -> Result<Vec<Candidate>> {
        panic!("stub")
    }

    /// Queue a download of one file from a user.
    pub async fn enqueue_download(
        &self,
        username: &str,
        filename: &str,
        size_bytes: u64,
    ) -> Result<()> {
        panic!("stub")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn start_search_posts_query_and_returns_id() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/searches"))
            .and(header("X-API-Key", "secret"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "abc-123"
            })))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        let id = client.start_search("daft punk around the world").await.unwrap();
        assert_eq!(id, "abc-123");
    }

    #[tokio::test]
    async fn fetch_results_normalizes_files_to_candidates() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v0/searches/abc-123/responses"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "username": "dj_alice",
                    "hasFreeUploadSlot": true,
                    "files": [
                        { "filename": "Daft Punk - Around the World.flac",
                          "size": 41000000, "bitRate": null, "length": 429, "extension": "flac" }
                    ]
                }
            ])))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        let candidates = client.fetch_results("abc-123").await.unwrap();
        assert_eq!(candidates.len(), 1);
        let only = &candidates[0];
        assert_eq!(only.username, "dj_alice");
        assert_eq!(only.format, "flac");
        assert!(only.has_free_upload_slot);
        assert_eq!(only.length_secs, Some(429));
    }

    #[tokio::test]
    async fn enqueue_download_posts_to_user_endpoint() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/transfers/downloads/dj_alice"))
            .respond_with(ResponseTemplate::new(201))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        client
            .enqueue_download("dj_alice", "Daft Punk - Around the World.flac", 41000000)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn http_error_surfaces_loudly() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/v0/searches"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let client = SlskdClient::new(server.uri(), "secret");
        let error = client.start_search("x").await.unwrap_err();
        assert!(matches!(error, SoulseekError::Slskd(_)));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core slskd_client`
Expected: FAIL (panic: stub).

- [ ] **Step 3: Implement the three methods**

```rust
    pub async fn start_search(&self, query: &str) -> Result<String> {
        let response = self
            .http
            .post(format!("{}/api/v0/searches", self.base_url))
            .header("X-API-Key", &self.api_key)
            .json(&serde_json::json!({ "searchText": query }))
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        let response = response
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        let created: SearchCreated = response
            .json()
            .await
            .map_err(|error| SoulseekError::SlskdProtocol(error.to_string()))?;
        Ok(created.id)
    }

    pub async fn fetch_results(&self, search_id: &str) -> Result<Vec<Candidate>> {
        let response = self
            .http
            .get(format!("{}/api/v0/searches/{}/responses", self.base_url, search_id))
            .header("X-API-Key", &self.api_key)
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        let responses: Vec<SearchResponse> = response
            .json()
            .await
            .map_err(|error| SoulseekError::SlskdProtocol(error.to_string()))?;

        let mut candidates = Vec::new();
        for entry in responses {
            for file in entry.files {
                let format = file
                    .extension
                    .map(|extension| extension.trim_start_matches('.').to_lowercase())
                    .or_else(|| {
                        std::path::Path::new(&file.filename)
                            .extension()
                            .and_then(|os| os.to_str())
                            .map(|extension| extension.to_lowercase())
                    })
                    .unwrap_or_default();
                candidates.push(Candidate {
                    username: entry.username.clone(),
                    filename: file.filename,
                    size_bytes: file.size,
                    bitrate_kbps: file.bit_rate,
                    format,
                    has_free_upload_slot: entry.has_free_upload_slot,
                    length_secs: file.length,
                });
            }
        }
        Ok(candidates)
    }

    pub async fn enqueue_download(
        &self,
        username: &str,
        filename: &str,
        size_bytes: u64,
    ) -> Result<()> {
        self
            .http
            .post(format!("{}/api/v0/transfers/downloads/{}", self.base_url, username))
            .header("X-API-Key", &self.api_key)
            .json(&serde_json::json!([{ "filename": filename, "size": size_bytes }]))
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?;
        Ok(())
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core slskd_client`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add rust-core/soulseek-core/src/slskd_client.rs
git commit -m "feat(soulseek-core): slskd REST client"
```

---

## Task 6: `AcquisitionPlanner` — pure `decide` + async `plan`

**Files:**
- Modify: `rust-core/soulseek-core/src/planner.rs`

- [ ] **Step 1: Write the failing tests for the pure `decide`**

Replace `rust-core/soulseek-core/src/planner.rs` with:

```rust
use serde::{Deserialize, Serialize};

use crate::candidate_ranker::rank;
use crate::error::Result;
use crate::slskd_client::SlskdClient;
use crate::types::{FormatPreference, ListEntry, ScoredCandidate};

/// How aggressively to commit downloads without a human in the loop.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfidencePolicy {
    pub auto_accept: bool,
    pub min_score: i64,
    pub require_free_slot: bool,
    /// Number of top candidates returned in the `Propose` case.
    pub propose_top_n: usize,
}

impl Default for ConfidencePolicy {
    fn default() -> Self {
        Self { auto_accept: false, min_score: 60, require_free_slot: true, propose_top_n: 5 }
    }
}

/// The planner's verdict for one entry.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Decision {
    AutoAccept(ScoredCandidate),
    Propose(Vec<ScoredCandidate>),
    Park { reason: String },
}

/// Pure decision over already-ranked candidates. No I/O.
pub fn decide(entry: &ListEntry, ranked: &[ScoredCandidate], policy: &ConfidencePolicy) -> Decision {
    panic!("stub")
}

fn clears_gate(entry: &ListEntry, top: &ScoredCandidate, policy: &ConfidencePolicy) -> bool {
    if top.score < policy.min_score {
        return false;
    }
    if policy.require_free_slot && !top.candidate.has_free_upload_slot {
        return false;
    }
    match entry.format_preference {
        FormatPreference::Flac => top.candidate.format.eq_ignore_ascii_case("flac"),
        FormatPreference::Lossy320Plus => {
            top.candidate.format.eq_ignore_ascii_case("flac")
                || top.candidate.bitrate_kbps.unwrap_or(0) >= 320
        }
        FormatPreference::Any => true,
    }
}

/// Search slskd, rank, and decide. The async orchestration; `decide`
/// holds the actual policy logic and is tested independently. `poll`
/// supplies the wait before fetching (slskd accumulates responses
/// asynchronously after a search starts).
pub async fn plan(
    entry: &ListEntry,
    client: &SlskdClient,
    policy: &ConfidencePolicy,
    poll: impl Fn(&str) -> std::time::Duration,
) -> Result<Decision> {
    use crate::query_builder::build_query;

    let search_id = client.start_search(&build_query(entry)).await?;
    tokio::time::sleep(poll(&search_id)).await;
    let candidates = client.fetch_results(&search_id).await?;
    let ranked = rank(entry, &candidates);
    Ok(decide(entry, &ranked, policy))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Candidate;

    fn entry() -> ListEntry {
        ListEntry {
            artist: "Daft Punk".into(), title: "Around the World".into(),
            album: None, year: None, duration_secs: Some(429),
            isrc: None, musicbrainz_recording_id: None,
            format_preference: FormatPreference::Any,
        }
    }

    fn scored(score: i64, slot: bool) -> ScoredCandidate {
        ScoredCandidate {
            candidate: Candidate {
                username: "u".into(), filename: "Daft Punk - Around the World.flac".into(),
                size_bytes: 1, bitrate_kbps: None, format: "flac".into(),
                has_free_upload_slot: slot, length_secs: Some(429),
            },
            score,
            notes: vec![],
        }
    }

    #[test]
    fn empty_candidates_parks() {
        let decision = decide(&entry(), &[], &ConfidencePolicy::default());
        assert!(matches!(decision, Decision::Park { .. }));
    }

    #[test]
    fn below_min_score_parks() {
        let policy = ConfidencePolicy { min_score: 100, ..Default::default() };
        let decision = decide(&entry(), &[scored(50, true)], &policy);
        assert!(matches!(decision, Decision::Park { .. }));
    }

    #[test]
    fn auto_off_proposes_top_n_even_when_gate_clears() {
        let policy = ConfidencePolicy { auto_accept: false, ..Default::default() };
        let decision = decide(&entry(), &[scored(140, true), scored(120, true)], &policy);
        match decision {
            Decision::Propose(list) => assert_eq!(list.len(), 2),
            other => panic!("expected Propose, got {other:?}"),
        }
    }

    #[test]
    fn auto_on_and_gate_clears_auto_accepts_top() {
        let policy = ConfidencePolicy { auto_accept: true, ..Default::default() };
        let decision = decide(&entry(), &[scored(140, true), scored(120, true)], &policy);
        match decision {
            Decision::AutoAccept(top) => assert_eq!(top.score, 140),
            other => panic!("expected AutoAccept, got {other:?}"),
        }
    }

    #[test]
    fn auto_on_but_no_free_slot_falls_back_to_propose() {
        let policy = ConfidencePolicy { auto_accept: true, require_free_slot: true, ..Default::default() };
        let decision = decide(&entry(), &[scored(140, false)], &policy);
        assert!(matches!(decision, Decision::Propose(_)));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core planner`
Expected: FAIL (panic: stub).

- [ ] **Step 3: Implement `decide`**

```rust
pub fn decide(entry: &ListEntry, ranked: &[ScoredCandidate], policy: &ConfidencePolicy) -> Decision {
    let Some(top) = ranked.first() else {
        return Decision::Park { reason: "no candidates returned by slskd".into() };
    };

    if top.score < policy.min_score {
        return Decision::Park {
            reason: format!("best candidate score {} below floor {}", top.score, policy.min_score),
        };
    }

    if policy.auto_accept && clears_gate(entry, top, policy) {
        return Decision::AutoAccept(top.clone());
    }

    let top_n = ranked.iter().take(policy.propose_top_n).cloned().collect();
    Decision::Propose(top_n)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core planner`
Expected: 5 tests PASS. (The async `plan` is exercised end-to-end by the MCP smoke test in Task 9; its parts — client, ranker, decide — are each unit-tested here and in Tasks 4–5.)

- [ ] **Step 5: Commit**

```bash
git add rust-core/soulseek-core/src/planner.rs
git commit -m "feat(soulseek-core): acquisition planner (decide policy + async plan)"
```

---

## Task 7: `DownloadConfirmer` + staging manifest

**Files:**
- Modify: `rust-core/soulseek-core/src/confirmer.rs`
- Modify: `rust-core/soulseek-core/src/staging.rs`

- [ ] **Step 1: Write the failing staging tests**

Replace `rust-core/soulseek-core/src/staging.rs` with:

```rust
use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::types::AcquisitionRecord;

/// Write one acquisition manifest next to its audio file in `staging/`.
/// The manifest filename is the audio filename with `.json` appended.
pub fn write_manifest(staging_dir: &Path, record: &AcquisitionRecord) -> Result<PathBuf> {
    panic!("stub")
}

/// Read one acquisition manifest back.
pub fn read_manifest(manifest_path: &Path) -> Result<AcquisitionRecord> {
    panic!("stub")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{FormatPreference, ListEntry, SourceInfo};

    fn record() -> AcquisitionRecord {
        AcquisitionRecord {
            list_entry: ListEntry {
                artist: "Daft Punk".into(), title: "Around the World".into(),
                album: None, year: None, duration_secs: Some(429),
                isrc: None, musicbrainz_recording_id: None,
                format_preference: FormatPreference::Any,
            },
            file_path: "/tmp/staging/track.flac".into(),
            fingerprint: vec![1, 2, 3, 4],
            source: SourceInfo {
                slskd_username: "dj_alice".into(),
                original_filename: "Daft Punk - Around the World.flac".into(),
                bitrate_kbps: None, format: "flac".into(), size_bytes: 41000000,
            },
            confirmed: true,
        }
    }

    #[test]
    fn manifest_round_trips() {
        let dir = std::env::temp_dir().join("crate-agent-test-staging");
        std::fs::create_dir_all(&dir).unwrap();
        let path = write_manifest(&dir, &record()).unwrap();
        let loaded = read_manifest(&path).unwrap();
        assert_eq!(loaded, record());
        std::fs::remove_file(&path).ok();
    }
}
```

- [ ] **Step 2: Run tests, verify fail, then implement staging**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core staging`
Expected: FAIL (panic: stub).

Implement (replace both `panic!("stub")` bodies):

```rust
pub fn write_manifest(staging_dir: &Path, record: &AcquisitionRecord) -> Result<PathBuf> {
    std::fs::create_dir_all(staging_dir)?;
    let audio_name = Path::new(&record.file_path)
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "download".to_string());
    let manifest_path = staging_dir.join(format!("{audio_name}.json"));
    let json = serde_json::to_string_pretty(record)?;
    std::fs::write(&manifest_path, json)?;
    Ok(manifest_path)
}

pub fn read_manifest(manifest_path: &Path) -> Result<AcquisitionRecord> {
    let json = std::fs::read_to_string(manifest_path)?;
    Ok(serde_json::from_str(&json)?)
}
```

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core staging`
Expected: PASS.

- [ ] **Step 3: Write the failing confirmer test (synthetic WAV)**

Replace `rust-core/soulseek-core/src/confirmer.rs` with:

```rust
use std::path::Path;

use crate::error::{Result, SoulseekError};
use crate::types::ListEntry;

/// Tolerance when comparing an entry's expected duration to the
/// downloaded file's actual duration.
pub const DURATION_CONFIRM_TOLERANCE_SECS: u64 = 8;

/// The verdict on a freshly downloaded file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Confirmation {
    pub fingerprint: Vec<u32>,
    pub duration_secs: u64,
    pub format: String,
    pub bitrate_kbps: Option<u32>,
    pub confirmed: bool,
    /// Populated when `confirmed == false`.
    pub reason: Option<String>,
}

/// Verify a downloaded file is real, decodable audio of roughly the
/// expected length, and compute its Chromaprint fingerprint (recorded
/// in the manifest for Phase 2 placeholder matching). A decode failure
/// is a hard error — the caller parks the entry rather than confirming.
pub fn confirm_download(file_path: &Path, entry: &ListEntry) -> Result<Confirmation> {
    panic!("stub")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::FormatPreference;

    fn write_sine_wav(path: &Path, seconds: u32) {
        let spec = hound::WavSpec {
            channels: 1, sample_rate: 44_100,
            bits_per_sample: 16, sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        let total = 44_100 * seconds;
        for index in 0..total {
            let t = index as f32 / 44_100.0;
            let sample = (t * 440.0 * 2.0 * std::f32::consts::PI).sin();
            writer.write_sample((sample * i16::MAX as f32) as i16).unwrap();
        }
        writer.finalize().unwrap();
    }

    fn entry(duration: Option<u64>) -> ListEntry {
        ListEntry {
            artist: "T".into(), title: "S".into(), album: None, year: None,
            duration_secs: duration, isrc: None, musicbrainz_recording_id: None,
            format_preference: FormatPreference::Any,
        }
    }

    #[test]
    fn confirms_valid_audio_matching_expected_duration() {
        let dir = std::env::temp_dir().join("crate-agent-test-confirm-ok");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ok.wav");
        write_sine_wav(&path, 12);
        let confirmation = confirm_download(&path, &entry(Some(12))).unwrap();
        std::fs::remove_file(&path).ok();
        assert!(confirmation.confirmed);
        assert!(!confirmation.fingerprint.is_empty());
        assert_eq!(confirmation.format, "wav");
    }

    #[test]
    fn flags_duration_mismatch_but_still_fingerprints() {
        let dir = std::env::temp_dir().join("crate-agent-test-confirm-drift");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("short.wav");
        write_sine_wav(&path, 5);
        let confirmation = confirm_download(&path, &entry(Some(300))).unwrap();
        std::fs::remove_file(&path).ok();
        assert!(!confirmation.confirmed);
        assert!(confirmation.reason.is_some());
        assert!(!confirmation.fingerprint.is_empty());
    }

    #[test]
    fn undecodable_file_is_a_hard_error() {
        let dir = std::env::temp_dir().join("crate-agent-test-confirm-bad");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("garbage.mp3");
        std::fs::write(&path, b"not audio at all").unwrap();
        let result = confirm_download(&path, &entry(None));
        std::fs::remove_file(&path).ok();
        assert!(matches!(result, Err(SoulseekError::Confirm(_))));
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core confirmer`
Expected: FAIL (panic: stub).

- [ ] **Step 5: Implement `confirm_download`**

```rust
pub fn confirm_download(file_path: &Path, entry: &ListEntry) -> Result<Confirmation> {
    use lofty::file::AudioFile;
    use lofty::probe::Probe;

    let fingerprint = fingerprint_core::fingerprint_file(file_path)
        .map_err(|error| SoulseekError::Confirm(format!("decode/fingerprint failed: {error}")))?;
    if fingerprint.is_empty() {
        return Err(SoulseekError::Confirm("fingerprint was empty".into()));
    }

    let tagged = Probe::open(file_path)
        .map_err(|error| SoulseekError::Confirm(format!("cannot open audio: {error}")))?
        .read()
        .map_err(|error| SoulseekError::Confirm(format!("cannot read audio properties: {error}")))?;
    let properties = tagged.properties();
    let duration_secs = properties.duration().as_secs();
    let bitrate_kbps = properties.audio_bitrate();
    let format = file_path
        .extension()
        .and_then(|os| os.to_str())
        .map(|extension| extension.to_lowercase())
        .unwrap_or_default();

    let (confirmed, reason) = match entry.duration_secs {
        Some(expected) if duration_secs.abs_diff(expected) > DURATION_CONFIRM_TOLERANCE_SECS => (
            false,
            Some(format!("duration {duration_secs}s differs from expected {expected}s")),
        ),
        _ => (true, None),
    };

    Ok(Confirmation { fingerprint, duration_secs, format, bitrate_kbps, confirmed, reason })
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core confirmer`
Expected: 3 tests PASS.

- [ ] **Step 7: Run the whole core + lint**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core`
Expected: all soulseek-core tests PASS.

Run: `make lint`
Expected: clippy clean across the workspace (warnings = errors).

- [ ] **Step 8: Commit**

```bash
git add rust-core/soulseek-core/src/confirmer.rs rust-core/soulseek-core/src/staging.rs
git commit -m "feat(soulseek-core): download confirmer + staging manifest"
```

---

## Task 8: `soulseek-mcp` binary (rmcp stdio server)

**Files:**
- Create: `rust-core/soulseek-mcp/Cargo.toml`
- Create: `rust-core/soulseek-mcp/src/main.rs`

The MCP server is a thin shell: each tool wires existing `soulseek-core` functions and holds session state. Config (`SLSKD_URL`, `SLSKD_API_KEY`, `SOULSEEK_STAGING_DIR`) is read from env and asserted at startup — fail fast on misconfiguration; the API key never appears in tool inputs or outputs.

- [ ] **Step 1: Create the binary manifest**

Create `rust-core/soulseek-mcp/Cargo.toml` (pin `rmcp` to the current `0.x` from docs.rs at implementation time; features shown are the stable server set):

```toml
[package]
name = "soulseek-mcp"
version = "0.1.0"
edition = "2021"
publish = false

[[bin]]
name = "soulseek-mcp"
path = "src/main.rs"

[dependencies]
soulseek-core = { path = "../soulseek-core" }
rmcp = { version = "0.9", features = ["server", "transport-io", "macros"] }
tokio = { version = "1", features = ["rt-multi-thread", "macros", "io-std", "time", "sync"] }
serde = { version = "1", features = ["derive"] }
schemars = "0.8"
anyhow = "1"
```

- [ ] **Step 2: Implement the server and tools**

Create `rust-core/soulseek-mcp/src/main.rs`:

```rust
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use rmcp::handler::server::wrapper::{Json, Parameters};
use rmcp::{tool, tool_router, ServiceExt};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use soulseek_core::adapters::text_paste::parse_text;
use soulseek_core::candidate_ranker::rank;
use soulseek_core::planner::{decide, ConfidencePolicy, Decision};
use soulseek_core::query_builder::build_query;
use soulseek_core::slskd_client::SlskdClient;
use soulseek_core::types::{ListEntry, ScoredCandidate};

struct Session {
    entries: Vec<ListEntry>,
    decisions: HashMap<usize, Decision>,
}

struct State {
    sessions: HashMap<String, Session>,
    policy: ConfidencePolicy,
    next_id: u64,
}

#[derive(Clone)]
struct SoulseekMcp {
    state: Arc<Mutex<State>>,
    client: SlskdClient,
    staging_dir: PathBuf,
    tool_router: rmcp::handler::server::tool::ToolRouter<Self>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct IngestParams { text: String }
#[derive(Serialize, schemars::JsonSchema)]
struct IngestResult { session_id: String, parsed: usize, skipped: Vec<String> }

#[derive(Deserialize, schemars::JsonSchema)]
struct SessionParams { session_id: String }
#[derive(Serialize, schemars::JsonSchema)]
struct PlanResult { auto_accepted: usize, proposed: usize, parked: Vec<String> }

#[derive(Deserialize, schemars::JsonSchema)]
struct ReviewParams { session_id: String, entry_index: usize }
#[derive(Serialize, schemars::JsonSchema)]
struct ReviewResult { entry: String, candidates: Vec<ScoredCandidate> }

#[derive(Deserialize, schemars::JsonSchema)]
struct ConfirmParams { session_id: String, entry_index: usize, candidate_index: usize }
#[derive(Serialize, schemars::JsonSchema)]
struct ConfirmResult { queued: bool, message: String }

#[derive(Deserialize, schemars::JsonSchema)]
struct AutoAcceptParams { enabled: bool, min_score: Option<i64> }
#[derive(Serialize, schemars::JsonSchema)]
struct PolicyResult { auto_accept: bool, min_score: i64 }

#[tool_router(server_handler)]
impl SoulseekMcp {
    fn new(client: SlskdClient, staging_dir: PathBuf) -> Self {
        Self {
            state: Arc::new(Mutex::new(State {
                sessions: HashMap::new(),
                policy: ConfidencePolicy::default(),
                next_id: 0,
            })),
            client,
            staging_dir,
            tool_router: Self::tool_router(),
        }
    }

    #[tool(description = "Parse a newline-delimited 'Artist - Title' list into a session.")]
    async fn ingest_list(&self, Parameters(params): Parameters<IngestParams>) -> Json<IngestResult> {
        let parsed = parse_text(&params.text);
        let mut state = self.state.lock().await;
        let id = format!("s{}", state.next_id);
        state.next_id += 1;
        let count = parsed.entries.len();
        state.sessions.insert(id.clone(), Session { entries: parsed.entries, decisions: HashMap::new() });
        Json(IngestResult { session_id: id, parsed: count, skipped: parsed.skipped })
    }

    #[tool(description = "Search slskd and decide (auto-accept / propose / park) for every entry in a session.")]
    async fn plan_acquisition(&self, Parameters(params): Parameters<SessionParams>) -> Json<PlanResult> {
        let entries = {
            let state = self.state.lock().await;
            match state.sessions.get(&params.session_id) {
                Some(session) => session.entries.clone(),
                None => return Json(PlanResult { auto_accepted: 0, proposed: 0, parked: vec!["unknown session".into()] }),
            }
        };

        let policy = { self.state.lock().await.policy.clone() };
        let mut decisions = HashMap::new();
        let (mut auto, mut proposed, mut parked) = (0usize, 0usize, Vec::new());

        for (index, entry) in entries.iter().enumerate() {
            let decision = match self.search_and_decide(entry, &policy).await {
                Ok(decision) => decision,
                Err(error) => Decision::Park { reason: error.to_string() },
            };
            match &decision {
                Decision::AutoAccept(_) => auto += 1,
                Decision::Propose(_) => proposed += 1,
                Decision::Park { reason } => parked.push(format!("{} - {}: {}", entry.artist, entry.title, reason)),
            }
            decisions.insert(index, decision);
        }

        let mut state = self.state.lock().await;
        if let Some(session) = state.sessions.get_mut(&params.session_id) {
            session.decisions = decisions;
        }
        Json(PlanResult { auto_accepted: auto, proposed, parked })
    }

    #[tool(description = "Show the ranked candidate list for one entry so it can be judged before download.")]
    async fn review_candidates(&self, Parameters(params): Parameters<ReviewParams>) -> Json<ReviewResult> {
        let state = self.state.lock().await;
        let (entry_label, candidates) = state
            .sessions
            .get(&params.session_id)
            .and_then(|session| {
                let entry = session.entries.get(params.entry_index)?;
                let candidates = match session.decisions.get(&params.entry_index) {
                    Some(Decision::Propose(list)) => list.clone(),
                    Some(Decision::AutoAccept(top)) => vec![top.clone()],
                    _ => vec![],
                };
                Some((format!("{} - {}", entry.artist, entry.title), candidates))
            })
            .unwrap_or_else(|| ("unknown entry".into(), vec![]));
        Json(ReviewResult { entry: entry_label, candidates })
    }

    #[tool(description = "Queue a chosen candidate for download in slskd.")]
    async fn confirm_download(&self, Parameters(params): Parameters<ConfirmParams>) -> Json<ConfirmResult> {
        let candidate = {
            let state = self.state.lock().await;
            state.sessions.get(&params.session_id).and_then(|session| {
                match session.decisions.get(&params.entry_index) {
                    Some(Decision::Propose(list)) => list.get(params.candidate_index).cloned(),
                    Some(Decision::AutoAccept(top)) if params.candidate_index == 0 => Some(top.clone()),
                    _ => None,
                }
            })
        };
        let Some(scored) = candidate else {
            return Json(ConfirmResult { queued: false, message: "no such candidate".into() });
        };
        match self
            .client
            .enqueue_download(&scored.candidate.username, &scored.candidate.filename, scored.candidate.size_bytes)
            .await
        {
            Ok(()) => Json(ConfirmResult { queued: true, message: format!("queued {}", scored.candidate.filename) }),
            Err(error) => Json(ConfirmResult { queued: false, message: error.to_string() }),
        }
    }

    #[tool(description = "Toggle high-confidence auto-accept and optionally set the minimum score.")]
    async fn set_auto_accept(&self, Parameters(params): Parameters<AutoAcceptParams>) -> Json<PolicyResult> {
        let mut state = self.state.lock().await;
        state.policy.auto_accept = params.enabled;
        if let Some(min) = params.min_score {
            state.policy.min_score = min;
        }
        Json(PolicyResult { auto_accept: state.policy.auto_accept, min_score: state.policy.min_score })
    }

    async fn search_and_decide(&self, entry: &ListEntry, policy: &ConfidencePolicy) -> soulseek_core::Result<Decision> {
        let search_id = self.client.start_search(&build_query(entry)).await?;
        tokio::time::sleep(Duration::from_secs(4)).await;
        let candidates = self.client.fetch_results(&search_id).await?;
        let ranked = rank(entry, &candidates);
        Ok(decide(entry, &ranked, policy))
    }
}

fn required_env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("required env var {key} is not set"))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let slskd_url = required_env("SLSKD_URL");
    let api_key = required_env("SLSKD_API_KEY");
    let staging_dir = PathBuf::from(required_env("SOULSEEK_STAGING_DIR"));

    let client = SlskdClient::new(slskd_url, api_key);
    let server = SoulseekMcp::new(client, staging_dir);

    let running = server.serve(rmcp::transport::stdio()).await?;
    running.waiting().await?;
    Ok(())
}
```

- [ ] **Step 3: Build the binary**

Run: `cargo build --manifest-path rust-core/Cargo.toml -p soulseek-mcp`
Expected: builds clean. If `rmcp` macro signatures differ from the pinned version, adjust the handler signatures to match the version's docs.rs examples (the `#[tool_router(server_handler)]` + `Parameters`/`Json` wrapper pattern is stable across 0.x). The `staging_dir` field is read by the `acquisition_status` tool added in Task 9 — if `cargo` warns it is unused after this task, leave it; Task 9 resolves the warning.

- [ ] **Step 4: Commit**

```bash
git add rust-core/soulseek-mcp
git commit -m "feat(soulseek-mcp): rmcp stdio server exposing the acquisition core"
```

---

## Task 9: `acquisition_status` (confirm-on-completion) + docs + smoke test

**Files:**
- Modify: `rust-core/soulseek-core/src/slskd_client.rs` (add `completed_downloads`)
- Modify: `rust-core/soulseek-mcp/src/main.rs` (add `acquisition_status` tool + confirmer/staging imports)
- Create: `docs/soulseek.md`
- Modify: `README.md`

- [ ] **Step 1: Add a completed-downloads test to `SlskdClient`**

In `rust-core/soulseek-core/src/slskd_client.rs`, add to the `tests` module:

```rust
    #[tokio::test]
    async fn completed_downloads_lists_finished_files() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v0/transfers/downloads"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                { "username": "dj_alice", "directories": [
                    { "files": [
                        { "filename": "Around the World.flac", "state": "Completed, Succeeded" },
                        { "filename": "Other.mp3", "state": "InProgress" }
                    ]}
                ]}
            ])))
            .mount(&server)
            .await;
        let client = SlskdClient::new(server.uri(), "secret");
        let done = client.completed_downloads().await.unwrap();
        assert_eq!(done, vec!["Around the World.flac".to_string()]);
    }
```

- [ ] **Step 2: Verify it fails, then implement `completed_downloads`**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core completed_downloads`
Expected: FAIL (method missing).

Add the deserialize structs (next to the existing `SearchResponse` structs):

```rust
#[derive(Debug, Deserialize)]
struct DownloadUser { directories: Vec<DownloadDirectory> }
#[derive(Debug, Deserialize)]
struct DownloadDirectory { files: Vec<DownloadFile> }
#[derive(Debug, Deserialize)]
struct DownloadFile { filename: String, state: String }
```

Add to `impl SlskdClient`:

```rust
    /// Filenames of downloads slskd reports as fully completed.
    pub async fn completed_downloads(&self) -> Result<Vec<String>> {
        let users: Vec<DownloadUser> = self
            .http
            .get(format!("{}/api/v0/transfers/downloads", self.base_url))
            .header("X-API-Key", &self.api_key)
            .send()
            .await
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .error_for_status()
            .map_err(|error| SoulseekError::Slskd(error.to_string()))?
            .json()
            .await
            .map_err(|error| SoulseekError::SlskdProtocol(error.to_string()))?;
        let mut done = Vec::new();
        for user in users {
            for directory in user.directories {
                for file in directory.files {
                    if file.state.contains("Completed") && file.state.contains("Succeeded") {
                        let name = std::path::Path::new(&file.filename)
                            .file_name()
                            .map(|os| os.to_string_lossy().to_string())
                            .unwrap_or(file.filename);
                        done.push(name);
                    }
                }
            }
        }
        Ok(done)
    }
```

Run: `cargo test --manifest-path rust-core/Cargo.toml -p soulseek-core slskd_client`
Expected: all PASS.

- [ ] **Step 3: Add the `acquisition_status` tool to the MCP server**

In `rust-core/soulseek-mcp/src/main.rs`, extend the imports:

```rust
use soulseek_core::confirmer::confirm_download;
use soulseek_core::staging::write_manifest;
use soulseek_core::types::{AcquisitionRecord, SourceInfo};
```

Add the result type near the other param/result structs:

```rust
#[derive(Serialize, schemars::JsonSchema)]
struct StatusResult {
    completed: Vec<String>,
    confirmed: Vec<String>,
    needs_review: Vec<String>,
}
```

Add inside the `#[tool_router(server_handler)] impl SoulseekMcp` block. This is where confirmation happens: any completed download is fingerprint-confirmed and a manifest is written into `staging/`; failures land in `needs_review` (a surface the operator reads, not a log line that scrolls past):

```rust
    #[tool(description = "Poll download progress; confirm + manifest finished files; report the needs-review list.")]
    async fn acquisition_status(&self) -> Json<StatusResult> {
        let completed = match self.client.completed_downloads().await {
            Ok(list) => list,
            Err(error) => return Json(StatusResult { completed: vec![], confirmed: vec![], needs_review: vec![error.to_string()] }),
        };

        let mut confirmed = Vec::new();
        let mut needs_review = Vec::new();

        for filename in &completed {
            let file_path = self.staging_dir.join(filename);
            if self.staging_dir.join(format!("{filename}.json")).exists() {
                continue; // already confirmed on a prior poll
            }
            if !file_path.exists() {
                needs_review.push(format!("{filename}: completed in slskd but not present in staging dir"));
                continue;
            }
            let entry = self.best_effort_entry_for(filename).await;
            match confirm_download(&file_path, &entry) {
                Ok(verdict) => {
                    let record = AcquisitionRecord {
                        list_entry: entry,
                        file_path: file_path.to_string_lossy().to_string(),
                        fingerprint: verdict.fingerprint,
                        source: SourceInfo {
                            slskd_username: String::new(),
                            original_filename: filename.clone(),
                            bitrate_kbps: verdict.bitrate_kbps,
                            format: verdict.format,
                            size_bytes: std::fs::metadata(&file_path).map(|meta| meta.len()).unwrap_or(0),
                        },
                        confirmed: verdict.confirmed,
                    };
                    match write_manifest(&self.staging_dir, &record) {
                        Ok(_) if verdict.confirmed => confirmed.push(filename.clone()),
                        Ok(_) => needs_review.push(format!("{filename}: {}", verdict.reason.unwrap_or_default())),
                        Err(error) => needs_review.push(format!("{filename}: manifest write failed: {error}")),
                    }
                }
                Err(error) => needs_review.push(format!("{filename}: {error}")),
            }
        }

        Json(StatusResult { completed, confirmed, needs_review })
    }

    /// Match a completed filename back to the list entry that requested
    /// it (by title containment across all sessions); falls back to a
    /// bare entry derived from the filename when no session claims it.
    async fn best_effort_entry_for(&self, filename: &str) -> ListEntry {
        let state = self.state.lock().await;
        let lowercase = filename.to_lowercase();
        for session in state.sessions.values() {
            for entry in &session.entries {
                if !entry.title.is_empty() && lowercase.contains(&entry.title.to_lowercase()) {
                    return entry.clone();
                }
            }
        }
        ListEntry {
            artist: String::new(),
            title: filename.to_string(),
            album: None, year: None, duration_secs: None,
            isrc: None, musicbrainz_recording_id: None,
            format_preference: Default::default(),
        }
    }
```

- [ ] **Step 4: Build + full workspace test + lint**

Run: `cargo build --manifest-path rust-core/Cargo.toml -p soulseek-mcp`
Expected: builds clean (no unused-`staging_dir` warning now).

Run: `make test-rust`
Expected: every workspace member's tests PASS (crate-agent-core, fingerprint-core, soulseek-core).

Run: `make lint`
Expected: clippy clean.

- [ ] **Step 5: Write the slskd + MCP usage doc**

Create `docs/soulseek.md` documenting: installing slskd on macOS (`brew install slskd` or release binary), pointing it at the Soulseek account (credentials live in slskd's own `slskd.yml`, never in crate-agent or the MCP), where the API key comes from, the three env vars the MCP needs (`SLSKD_URL`, `SLSKD_API_KEY`, `SOULSEEK_STAGING_DIR`), the Claude MCP registration snippet, and the tool-by-tool flow (`ingest_list` → `plan_acquisition` → `review_candidates`/`set_auto_accept` → `confirm_download` → `acquisition_status`). State explicitly that the official SoulseekQt app is NOT used and that Phase 2 (crate-agent placeholder sync) is gated on Pillar C.

MCP registration snippet to include in the doc:

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

- [ ] **Step 6: Update the README**

In `README.md`, add a short "Soulseek acquisition (MCP)" subsection under the existing feature/roadmap framing: one paragraph on what it does (drive Soulseek downloads from a list via Claude through slskd), that it's a standalone Phase 1 with crate-agent sync arriving in Phase 2, the build command (`cargo build --manifest-path rust-core/Cargo.toml -p soulseek-mcp --release`), and a link to `docs/soulseek.md`. Keep the README within its length budget — details go in the doc, not the README.

- [ ] **Step 7: Manual smoke test (requires a running slskd)**

With a local slskd running and the three env vars exported, run the MCP binary and drive it from Claude (or an MCP inspector):

```bash
cargo build --manifest-path rust-core/Cargo.toml -p soulseek-mcp --release
SLSKD_URL=http://localhost:5030 SLSKD_API_KEY=... SOULSEEK_STAGING_DIR=~/Music/_staging \
  ./rust-core/target/release/soulseek-mcp   # speaks MCP over stdio
```

Verify the loop end-to-end: `ingest_list` a 2-line list → `plan_acquisition` returns candidates → `confirm_download` queues in slskd's web UI → after the transfer completes, `acquisition_status` reports it `confirmed` and a `<file>.json` manifest with a non-empty `fingerprint` array appears in the staging dir.

- [ ] **Step 8: Commit**

```bash
git add rust-core/soulseek-core/src/slskd_client.rs rust-core/soulseek-mcp/src/main.rs docs/soulseek.md README.md
git commit -m "feat(soulseek-mcp): acquisition status with confirm-on-completion + docs"
```

---

## Self-Review

**Spec coverage:**
- slskd substrate, localhost, token from env → Task 8 (`required_env`), Task 9 doc. ✓
- Shared core in `rust-core`, MCP thin shell → Tasks 1–8. ✓
- Five units (SlskdClient, QueryBuilder, CandidateRanker, AcquisitionPlanner, DownloadConfirmer) → Tasks 5, 3, 4, 6, 7. ✓
- I/O isolated; pure ranking unit-tested → Tasks 3/4/6 pure, Task 5 wiremock, Task 7 synthetic WAV. ✓
- Rich `ListEntry` mirroring placeholder schema + text-paste adapter → Tasks 1, 2. ✓
- Propose-then-confirm + high-confidence auto-accept toggle → Task 6 (`decide`, `ConfidencePolicy`), Task 8 (`set_auto_accept`). ✓
- `staging/` + `AcquisitionRecord` manifest with `fingerprint` join key → Tasks 1, 7, 9. ✓
- Shared fingerprint mechanic, not duplicated → Task 0 (`fingerprint-core`). ✓
- Secrets via env assert, loud failures (needs-review surface) → Task 8 env asserts, Task 9 `needs_review`. ✓
- Phase 2 explicitly out of scope → stated in Goal/Architecture; no crate-agent code touched beyond the fingerprint extraction. ✓

**Placeholder scan:** every code step contains complete code; the `panic!("stub")` bodies are strict-TDD red-state stubs replaced within the same task (Step 3/5), not deferred work. The only specifics resolved at implementation time are external contracts (exact slskd JSON shapes, exact `rmcp` minor version) — pinned by tests and flagged explicitly, not silently. ✓

**Type consistency:** `ListEntry`, `Candidate`, `ScoredCandidate`, `Decision`, `ConfidencePolicy`, `AcquisitionRecord`, `SourceInfo`, `Confirmation` are defined once (Tasks 1, 6, 7) and referenced with matching field names throughout the MCP server (Tasks 8/9). `SlskdClient` methods (`start_search`, `fetch_results`, `enqueue_download`, `completed_downloads`) match between definition (Tasks 5, 9) and call sites (Tasks 6, 8, 9). ✓
