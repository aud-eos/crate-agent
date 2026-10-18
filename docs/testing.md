# Test isolation

Run `make test-swift` (or `make test` for Rust and Swift). Build the Rust library
and bindings with `make build-rust` first on a fresh checkout.

The generated CrateAgent scheme uses the **Test** configuration for its Test
action. That configuration compiles `CRATE_AGENT_TEST_HOST` into the app and uses
`com.crateagent.CrateAgent.TestHost` as its bundle identifier. It therefore stays
inactive before XCTest loads, and AppKit window state uses a separate preferences
domain. Normal Debug/Release launches retain the production startup path.

For a direct command:

```sh
xcodegen generate
xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent \
  -configuration Test -derivedDataPath build-output/DerivedData test
```

Do not override the test configuration with Debug or Release. Runtime XCTest
detection still blocks live services, but those configurations share the normal
app's AppKit preferences domain. The host-isolation regression test rejects that
configuration.

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`.
A newer push to the same PR cancels the older run.

- **Ubuntu:** `make format-check`, `make lint` and `make test-rust`. SwiftFormat
  is pinned by `SWIFTFORMAT_VERSION`; bump it together with a local reformat.
- **macOS 26 with Xcode 26.6:** `make build-rust`, `make xcodeproj` and the full
  Swift suite in the Test configuration. It mounts the disposable APFS volume
  described below first, so the volume-dependent tests run instead of skipping.

Cargo builds and SPM checkouts are cached. A failing Swift run uploads its
`.xcresult` bundle as an artifact.

## Adding tests

- Exercise launcher transitions through `ApplicationLauncher`, injecting a
  `PreferencesStore` and a service factory. `IsolatedPreferences` owns a unique
  defaults suite and removes it when released. Keep fixture references alive for
  the duration of the test.
- Exercise services directly with in-memory databases, temporary audio/Serato
  directories, and controlled lifecycle sources. Do not construct live
  `AppServices`; its initializer rejects XCTest before starting any work.
- `LibraryDatabase.openDefault()`, `SeratoLibraryLocator.defaultLocation()`, and
  `PreferencesStore.live()` also reject XCTest before accessing production
  resources. `UserPreferences` is the production facade; use an injected store
  in tests. Never clear or restore the user's standard preferences as test setup.
- Stop any fixture-owned workers/watchers and await their completion before
  deleting temporary files. The host itself starts none.

This is an application startup boundary, not an operating-system sandbox. Tests
that bypass these factories and explicitly open arbitrary paths still need
isolated fixtures. A green suite alone is not evidence that new test code respects
that contract.


## Owned APFS volume fixture

Native Trash, cross-volume and case-alias tests skip unless a disposable APFS
volume is mounted at `/private/tmp/crate-agent-task6-volume` with a
`.task6-test-volume` marker. It must be case-insensitive (plain `APFS`):

```sh
hdiutil create -size 200m -fs APFS -volname CrateTask6 -type SPARSE /path/to/task6.sparseimage
mkdir -p /private/tmp/crate-agent-task6-volume
hdiutil attach /path/to/task6.sparseimage -mountpoint /private/tmp/crate-agent-task6-volume
touch /private/tmp/crate-agent-task6-volume/.task6-test-volume
touch /private/tmp/crate-agent-task6-volume/.trash-seed
swift -e 'import Foundation; try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), resultingItemURL: nil)' \
  /private/tmp/crate-agent-task6-volume/.trash-seed
```

Don't attach it with `-nobrowse`: FSEvents keeps no event history for a nobrowse
volume, so the cursor-replay test would pass or fail on timing alone (#234).

The last step creates the volume's `.Trashes/<uid>`. On a fresh volume,
`FileManager.url(for: .trashDirectory, …, create: true)` fails with "feature not
supported" until a native trash has created that directory.

Tests trash files only into that volume's own `.Trashes`, never the user's Trash.
The mount is machine-wide, so it un-skips these tests for every concurrent suite;
detach it (`hdiutil detach /private/tmp/crate-agent-task6-volume`) when done.

## Paged Library fixture

`LibraryPagingTests` creates one temporary WAL database with 30,000 synthetic
files. It never opens the owner's library or creates audio. Run it in the isolated
Test host:

```sh
xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent -configuration Test \
  -derivedDataPath build-output/DerivedData \
  -only-testing:CrateAgentTests/LibraryPagingTests test
```

The `PAGED_LIBRARY_METRICS` log and XCTest attachment report Library rendering
inside an existing window, distant scrollbar work, initial/distant asynchronous
load latency, maximum main-actor heartbeat delay, decoded row totals, and peak
cached rows. Rendering and scroll gestures run in separate main-actor turns,
with a short idle interval between interactions. OS window setup is reported separately. Targets are below 100 ms for
rendering and below 50 ms for main-thread work; timings are measured evidence,
not machine-dependent pass/fail thresholds. The normal cache bound is 1,000 rows
(200 per page, five pages); oversized viewports declare a larger effective page
size while retaining the five-page bound. Memory and identity assertions are
hard requirements. Generic controller tests cover controlled stale completions
and error/retry races, and native table tests cover deferred selection and context
IDs independently of Library's row type.


## Duplicate scan fixture

`DuplicateScanPerformanceTests` builds a temporary WAL database with 30,000
processable files: 32-byte lightweight hashes on all of them, 4 KB Chromaprint
fingerprints on 24,000, 300 byte-level pairs with
cached content digests and 1,650 perceptual pairs with cached audio digests (the owner's 3,300 colliding files). It runs both duplicate
modes plus fingerprint coverage, asserts that only the 3,900 group members are
decoded, and asserts a 1 s budget. `DUPLICATE_SCAN` output
is attached as evidence. Before SQL grouping, the same fixture took 1.34 s to
load every full row and group it in Swift; the SQL scan takes about 0.17 s.

## Local builds while using the Mac

Use one native build at a time, keep the same DerivedData location between runs,
and avoid routine clean builds. For lower contention on an Apple Silicon Mac:

```sh
nice -n 10 xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent \
  -configuration Test -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build-output/DerivedData -jobs 1 \
  -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
  SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO test
```

This reduces concurrency and scheduling priority; it is not a hard CPU cap.
Xcode's integrated scheduler owns individual compiler tasks, and Xcode can append
its own Swift `-j` argument after `OTHER_SWIFT_FLAGS`. Do not assume adding `-j1`
there controls the effective compiler invocation. Retain architecture coverage in
release/CI checks. Avoid running Rust and Swift builds simultaneously; use `cargo
-j 1` for the corresponding Rust command. Focused XCTest selectors reduce executed
tests but still compile the test target; run the full suite before opening a PR.

## Serato conflict fixtures

`SeratoConflictAnalysisTests` includes a temporary WAL database with 30,000 indexed
rows and 30,002 saved occurrences. It measures analysis separately from startup
scanning, verifies two diagnostic probes for two raw conflicting spellings, and
samples main-actor responsiveness. The analysis target is 100 ms; the main-actor
gap assertion is 50 ms. Timing output is attached as `CONFLICT_PERF` evidence.
The test does not open production data or synthesize 30,000 audio files.

`SeratoConflictPresentationTests` mounts the actual repair view, routes explicit
native actions through injected boundaries, retains stale/error evidence, and
exports light/dark Comfortable/Compact renders to `/tmp/crate-130-conflict-renders`.
`CONFLICT_NAV` records hosted navigation time against a 500 ms assertion. These
figures describe the new conflict work, not overall incremental-startup performance.

Run these suites with `-only-testing:CrateAgentTests/SeratoConflictAnalysisTests`
and `-only-testing:CrateAgentTests/SeratoConflictPresentationTests` added before
`test` in the isolated native command above. Session, mutation, worker, import,
selection, and Rust FFI tests cover safety at their existing public boundaries.

Owner-app smoke check: open **Review conflicts**, compare both saved spellings and
metadata, copy the details, reveal a verified file, and explicitly open Serato.
Preserve the intended audio and crate references, save and close Serato, retry,
and confirm conflict counts clear. Automated fixtures never perform this repair
against the owner's library.


On the reference Mac with serial, lower-priority Test builds, observed analysis
wall times ranged from 233–560 ms. The final formatted-tree run measured
557 ms, 3.7 ms maximum main-actor gap, and 66–108 ms hosted navigation; the
preceding full run measured 233 ms, about 2 ms, and 34–56 ms respectively.
The 100 ms analysis target remains unmet in this unoptimized configuration.
Correctness, two-probe scaling, main-actor responsiveness, and navigation limits
passed. These measurements were not rerun to select a favorable sample.
VoiceOver navigation remains part of the owner-app smoke check: the in-process
AppKit accessibility tree exposes selectable text but not all SwiftUI controls,
so it is not used as an oracle for the screen's buttons.


## Incremental startup fixture

`LibraryStartupPerformanceTests` uses 30,000 real, separate 108-byte WAV files,
encoded V2 records, and a temporary WAL store. It runs full validation to populate
the checkpoint, reopens the store with fresh services, and measures the production
startup coordinator through readiness. The empty replay boundary is controlled;
`FilesystemReplayBoundaryTests` separately exercise real native event delivery.

The same fixture then changes one saved title and suspends parsing at an explicit
barrier. It mounts the production sidebar and `LibraryPagedContent`, selects a
sidebar row before releasing sync, and measures content rendering and navigation.
It does not construct live `AppServices` or the complete History destination.
Blank AppKit window creation is outside content-render timing. This keeps tests
isolated from the owner's library and preferences.

Use the same optimized **Test** settings for baseline and final measurements:

```sh
nice -n 10 xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent \
  -configuration Test -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build-output/DerivedData-StartupOptimized \
  -jobs 1 -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
  SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule \
  ENABLE_HARDENED_RUNTIME=NO \
  -only-testing:CrateAgentTests/LibraryStartupPerformanceTests test
```

The hardened-runtime override applies only to this isolated ad-hoc Test host;
without it the optimized XCTest bundle can fail its Team ID check. Production
signing settings stay intact. Xcode may not pass its niceness to the test child;
only lower the priority of the matching Test-host executable when needed.

`STARTUP_FULL`, `STARTUP_RESTART`, and `STARTUP_NAVIGATION` appear in the log and
XCTest attachments. Hard assertions require ready within two seconds, content
rendering/navigation within 500 ms, zero unchanged parser/tag/bitrate/hash reads,
and one changed row after a single parse. The slow-path sync after that parse
(`slow_path_after_parse`) must finish within 30 s; it measured 34.8 s before path keys
hashed their full bytes (#218) and 12.6 s after, in the optimized settings above.
Phase timings contain no paths or metadata.
The file cache is warm after setup; tiny WAVs, one temporary directory, and a
controlled replay boundary do not predict cold-disk or external-drive latency.

Reference run on 2026-10-12, native arm64 with the optimized settings above:

| Measurement | Time |
| --- | ---: |
| Previous full-sync baseline (product base `b83deec`) | 100.061 s |
| Current full validation and checkpoint population | 101.755 s |
| Unchanged restart with reopened WAL store | 0.099 s |
| Production content rendering during held changed-source sync | 105 ms |
| Production sidebar selection during the same sync | 6 ms |

The unchanged run performed 30,000 stat checks and zero parser, tag, bitrate, or
hash reads. The changed-title pass parsed once, updated one row, and read no audio.
These are warm-fixture measurements, not a promise for every disk or library.


Owner-app smoke check: launch against an already indexed library, navigate/search
while validation runs, then relaunch unchanged; change one Serato title and close
Serato; verify that title updates and unrelated rows remain available. In Workers,
exercise **Re-scan File Info**, **Stop Sync**, and **Retry Sync**. Inspect any file-info errors
and path conflicts before attempting processing on affected files.

## Planning large-library work

Plans touching startup, navigation, scanning, or bulk operations must start with
the user journey, expected library size, interaction/ready budgets, and what stays
usable during validation. Define a production-scale fixture and an actual-screen
smoke checklist before implementation. Small correctness fixtures alone do not
prove responsiveness; compare baseline and final measurements with the same data
and build settings. See issues 120 and 129 for the failures this requirement prevents.

## Queued drain writer hold

A drain applies each segment's I/O, physical-target checks and confirmations in
one writer transaction. Writes elsewhere wait for it, though WAL reads do not.
The budget is 500 ms per transaction. `SeratoWriteSegmenter.maximumEntriesPerSegment`
bounds a segment at 200 rows (#189).

Reference measurements on 2026-10-17, Test build, measured on the 30,000-file
`LibraryStartupPerformanceFixture`:
- **Scenario:** 1,000 rows of each batched kind are queued while Serato runs, then drained after it quits.
- **Measured:** the longest wait of a probe that issues an empty write every 5 ms.
- **Method:** a scratch test, not committed, run with identical data and settings before and after.

| Kind | Before | After |
| --- | ---: | ---: |
| V2 metadata | 510 ms | 125 ms |
| Rename | 413 ms | 88 ms |
| Add | 1,105 ms | 232 ms |

Total drain time is unchanged, at 1.4 to 2.1 s per 1,000 rows. A 26.7 MB `database V2`
rewrite costs 40 to 60 ms, whatever the row count. The cap therefore costs about one
extra library rewrite per 200 rows.

## Checkpoint publish writer hold

A sync that leaves the fast path republishes the whole checkpoint: one saved
occurrence per V2 record, plus evidence and a stat row per file. It used to write
all of them in one writer transaction. Publication now stages a new generation in
1,000-row transactions and makes it current in one short transaction (#238; see
the incremental checkpoint section of `serato-membership-reconciliation.md`).

`LibraryStartupPerformanceTests` asserts the budget. After its navigation step,
it changes one saved title and runs a sync while `WriterHoldProbe` issues an empty
write every 5 ms. It records the longest wait and the sync phase it ended in, and
requires every wait to stay under 500 ms. `STARTUP_WRITER_HOLD` reports the
result.

Reference run on 2026-10-18, on the 30,000-file fixture, with the optimized
**Test** settings above. Both runs use identical test code; the baseline is
`4ed1fcc` with the probe step added uncommitted.

| Longest writer wait | Baseline (`4ed1fcc`) | Generation staging |
| --- | ---: | ---: |
| Applying queued changes (checkpoint publish) | 941 ms | 38 ms |
| Any phase | 941 ms | 243 ms (Refreshing file info) |

The probe made about 3,400 writes in each run.

## Fingerprint backlog responsiveness

`FingerprintResponsivenessTests` exercises a 30,000-row pending library while the
real Rust decoder fingerprints 120-second, 44.1 kHz mono WAV audio. Each row has a
separate temporary symlink to the same generated tone; missing lightweight hashes
prevent byte-twin reuse from eliminating the decode workload. The database uses
WAL, and no owner audio, preferences, or live `AppServices` are accessed.

The fixture mounts the production Library content and sidebar, repeatedly scrolls
to distant rows and switches sidebar selection, and records main-actor scheduling
gaps. As in the app, the window opens before the Library model loads, so rendering
runs from the model's start until the first rows are visible in that window. The
heartbeat also covers the window's own setup turn. Rendering, scroll completion,
sidebar selection, and maximum main-actor gap must each stay below 500 ms while the
backlog remains active. At least one batch
must persist successful fingerprints, with no failed decodes. These measurements
exercise scheduling and database/UI contention on warm, repeated PCM audio; they
do not establish throughput for a diverse collection or cold external storage.
The sidebar fixture does not mount the full destination screens.

Use the optimized isolated Test command above with
`-only-testing:CrateAgentTests/FingerprintResponsivenessTests` and identical build
settings for baseline and final results. `FINGERPRINT_RESPONSIVENESS` records the
measurements in the log and an XCTest attachment. The lifecycle regression holds
one decoder at the audio boundary, requests stop/restart, and verifies the pool
never exceeds its configured limit and remaining files finish with intact results.

Owner-app smoke checklist: with a substantial fingerprint backlog, browse and
scroll Library, search, switch to Organize and back, and inspect progress. Repeat a
file-info rescan or Serato open/close transition while fingerprinting is active;
processing should resume when authorized without overlapping decoder pools.
Completed fingerprints should remain available after quitting and reopening.

Reference measurements on 2026-10-12, optimized native arm64 Test build:

| Measurement | Before lifecycle fix | After lifecycle fix |
| --- | ---: | ---: |
| Library rendering | 315 ms | 204 ms |
| Maximum distant-row scroll completion | 169 ms | 339 ms |
| Maximum sidebar selection | 9 ms | 6 ms |
| Maximum main-actor scheduling gap | 303 ms | 320 ms |

Both steady-state runs meet the budget; these individual samples do not establish
a throughput or latency improvement. The lifecycle regression establishes the
correctness improvement: a stop/restart previously reached two simultaneous
decoders with a limit of one; the corrected worker stays at one and resumes its
pending files. Existing background priority, quarter-core concurrency, and batch
cooldown remain unchanged.
