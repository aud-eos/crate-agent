# crate-agent

A macOS-native companion app for Serato DJ library management.

`crate-agent` sits alongside Serato DJ, watches your filesystem, and keeps Serato's library in sync when you rename or move music files in Finder — the bug that has annoyed every working Serato DJ since 2005. It is also being built to grow into a full library-management toolkit: MusicBrainz auto-tagging, format conversion with cue-point preservation, library hygiene tools, Spotify playlist matching, chart-gap analysis, and more.

**Status:** SP-1 in development. See [design plan](#design-plan) below.

## Why this exists

Serato stores absolute file paths in its binary library files. When you rename a file in Finder, Serato silently loses access to it. Serato has no public API, plugin system, or library-management hooks. Third-party tools that bridge the gap (Lexicon, Rekordbuddy) are excellent but commercial; this project exists to be a small, focused, native alternative that the author can shape to fit their own DJ workflow.

## Architecture (one paragraph)

Swift / SwiftUI macOS app with a hybrid window-plus-menu-bar shape. The Serato library read/write path goes through a Rust core (wrapping the `triseratops` crate) bridged to Swift via `uniffi`. Audio fingerprinting uses `chromaprint`. Tag I/O uses `lofty`. State lives in a SQLite database via GRDB.swift, with an event-sourced schema that powers both undo and per-file history. Every state-changing operation goes through a single "apply track mutation" primitive — the architectural keystone — so new features (auto-tag, re-encode, rule engine, etc.) add a mutation type rather than a new code path.

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

### Test

```sh
make test           # All tests (Rust + Swift)
make test-rust      # Only Rust core
make test-swift     # Only Swift app
```

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
rust-core/         Rust crate: Serato I/O, fingerprinting, tag I/O
scripts/           Build scripts
test-fixtures/     Sample Serato library files and audio for tests
```

## License

TBD. Intended for personal use by the author for now.
