# crate-agent

A macOS-native companion app for Serato DJ library management.

`crate-agent` sits alongside Serato DJ, watches your filesystem, and keeps Serato's library in sync when you rename or move music files in Finder — the bug that has annoyed every working Serato DJ since 2005. It is also being built to grow into a full library-management toolkit: MusicBrainz auto-tagging, format conversion with cue-point preservation, library hygiene tools, Spotify playlist matching, chart-gap analysis, and more.

**Status:** SP-1 (Serato rename-sync), SP-1.5 (library hygiene tools), and SP-2 (MusicBrainz auto-tagging — the Auto-Tag panel, which needs a free [AcoustID API key](https://acoustid.org) set in Settings) are shipped, along with a desktop-scale performance pass. Soulseek acquisition Phase 1 is shipped as a standalone MCP server (see [below](#soulseek-acquisition-mcp)). Next planned milestone is SP-3 (rule engine for proactive auto-rename). See [design plan](#design-plan) below.

Auto-Tag supports browsing untagged tracks, List or Focus review, and choosing
between recording candidates. Scans and review choices survive navigation to
other screens while the app remains open. See the [Auto-Tag guide](docs/auto-tag.md).
Use the shared Comfortable/Compact density setting to adjust spacing throughout
the app.

In **Library**, use **Re-scan File Info** to check Serato's complete saved library;
the scan stays off at startup and can be stopped while it is running. Fingerprinting
continues as independent background work. Removing a track from Serato
retires its crate-agent entry while preserving the audio, recording identity, and
History. Missing audio that Serato still references remains a member but cannot
be processed. The main window and menu bar show waiting, sync results, or an error
with **Retry Sync**. A missing or unreadable Serato database stops synchronization;
it never means that every track was removed. See the
[reconciliation contract](docs/serato-membership-reconciliation.md).

If an import cannot update Serato, it remains pending and the sync status offers
**Retry Sync**. Restore access to the Serato library and retry without dropping the
audio again. Pending retries currently survive only while crate-agent stays open.

In **Library**, use **Active**, **Removed from Serato**, or **Missing** to inspect
current membership and availability. Right-click a file for **Show History**;
retired entries keep their last normal path and cannot be processed. Missing
includes offline volumes, access failures, and unknown availability, each labeled
separately. Serato offers library-only removal and removal with a move to Trash;
crate-agent retirement itself never moves, deletes, or restores audio.
Re-adding verified audio in Serato can reactivate its retained entry; restoring
audio alone does not re-import it. Reconciliation currently supports the configured
local Serato library, not independent libraries on external volumes. Offline
volumes cannot provide evidence for retirement.

**Organize** builds a cancellable preview in the background. Numeric-leading
artists use the existing `_0123456789` folder. Start with no files
selected, review every result using the scrollbar, then choose individual files
or **Select all eligible matches** in the current filter. Files missing Artist,
Title or another tag used by the filename template show what they need and stay
in place. Selections survive filter changes; the footer and confirmation count
hidden selections. See the
[Organize guide](docs/organize.md).

**Move library** validates each previewed file before moving it. Files that changed
or became unavailable stay in place; successful moves remain undoable together in
History. Partial migration keeps the current library-folder setting. See the
[migration and recovery guide](docs/library-migration.md).

## Why this exists

Serato stores absolute file paths in its binary library files. When you rename a file in Finder, Serato silently loses access to it. Serato has no public API, plugin system, or library-management hooks. Third-party tools that bridge the gap (Lexicon, Rekordbuddy) are excellent but commercial; this project exists to be a small, focused, native alternative that the author can shape to fit their own DJ workflow.

## Architecture (one paragraph)

Swift / SwiftUI macOS app with a hybrid window-plus-menu-bar shape. The Serato library read/write path goes through a Rust core (wrapping the `triseratops` crate) bridged to Swift via `uniffi`. The Rust side is a Cargo workspace: `crate-agent-core` (Serato + tag I/O, the FFI surface), `fingerprint-core` (Chromaprint, shared), plus `soulseek-core` and the `soulseek-mcp` server binary. Audio fingerprinting uses `chromaprint`. Tag I/O uses `lofty`. State lives in a SQLite database via GRDB.swift, with an event-sourced schema that powers both undo and per-file history. Every state-changing operation goes through a single "apply track mutation" primitive — the architectural keystone — so new features (auto-tag, re-encode, rule engine, etc.) add a mutation type rather than a new code path.

## Design plan

The full design is at [`design-plan.md`](./design-plan.md) (copied from the original brainstorming session). Read it before contributing — it documents the locked-in foundational decisions (track identity model, folder organization philosophy, sub-project sequencing) and the rationale behind them.

## Setup

Common operations are wrapped in the [`Makefile`](./Makefile). Run `make` with no arguments to see the full list.

### One-time setup

```sh
make install-deps   # Rust toolchain, xcodegen, swiftformat
make doctor         # Verify everything's on PATH
```

Xcode itself must be installed via the App Store separately; after install, point `xcode-select` at it:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

### Build & run

```sh
make build          # Rust core + Xcode project + app (Debug)
make run            # Open the built CrateAgent.app
```

Both commands use this checkout's `build-output/DerivedData` directory, so
`make run` cannot pick an older app from another worktree or Xcode build.
Run `make build` once after updating to this layout. `make clean` removes this
checkout's build, while builds made directly in Xcode remain separate.

Run `python3 scripts/test-make-run.py` to check build/launch path selection
without launching the app.

### Test

```sh
make test           # All tests (Rust + Swift)
make test-rust      # Only Rust core
make test-swift     # Only Swift app
```

`make test-swift` uses the **Test** configuration, whose app host has a separate
bundle identifier and never starts live application services. The generated
CrateAgent scheme also selects Test for Xcode's Test action. Keep that configuration
when invoking `xcodebuild` directly; overriding it with Debug or Release loses the
separate AppKit preferences domain. Live database, Serato-location, and preference
factories reject calls from XCTest. Launcher tests inject isolated preferences and
service factories; service integration tests use in-memory databases and temporary
library fixtures. See [test isolation](docs/testing.md) for the contract.

### Iterate

```sh
make format         # cargo fmt + swiftformat
make lint           # cargo clippy
make clean          # Remove all generated artifacts (target/, build-output/, etc.)
```

## Soulseek acquisition (MCP)

`soulseek-mcp` is a standalone MCP binary that lets Claude drive Soulseek downloads from a tracklist via a local [slskd](https://github.com/slskd/slskd) daemon — search, rank candidates, queue downloads, fingerprint + manifest completed files. This is Phase 1 (standalone acquisition); Phase 2 (syncing downloads into the crate-agent library via Chromaprint match) is gated on Pillar C.

```sh
cargo build --manifest-path rust-core/Cargo.toml -p soulseek-mcp --release
```

See [`docs/soulseek.md`](./docs/soulseek.md) for setup, env vars, Claude MCP registration, and smoke-test steps.

## Project layout

```
CrateAgent/        Swift app (SwiftUI, AppKit hooks where needed)
CrateAgentTests/   Swift test suite
rust-core/         Cargo workspace (see crates below)
scripts/           Build scripts
docs/              Design docs, Soulseek setup, planning artifacts
```

`rust-core/` is a Cargo workspace:

```
src/               crate-agent-core package: Serato/tag I/O and the Swift FFI surface
fingerprint-core/  Chromaprint audio fingerprinting (shared by crate-agent-core and soulseek-core)
soulseek-core/     Soulseek acquisition logic (slskd client, candidate ranking, download confirmation)
soulseek-mcp/      MCP server binary exposing soulseek-core to Claude
```

## License

TBD. Intended for personal use by the author for now.
