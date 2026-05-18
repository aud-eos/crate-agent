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

### Prerequisites

```
# Rust toolchain (for the rust-core crate)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# XcodeGen (regenerates CrateAgent.xcodeproj from project.yml)
brew install xcodegen

# Xcode 15 or later (for the Swift app build)
```

### Build

```
# 1. Build the Rust core as a universal static library
./scripts/build-rust.sh

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. Open in Xcode and build
open CrateAgent.xcodeproj
```

## Project layout

```
CrateAgent/        Swift app (SwiftUI, AppKit hooks where needed)
rust-core/         Rust crate: Serato I/O, fingerprinting, tag I/O
scripts/           Build scripts
test-fixtures/     Sample Serato library files and audio for tests
```

## License

TBD. Intended for personal use by the author for now.
