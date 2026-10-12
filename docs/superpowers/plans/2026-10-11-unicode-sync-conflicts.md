# Unicode Sync Conflicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synchronize unaffected library entries while retaining, blocking and explaining ambiguous Unicode-equivalent Serato records, with guided repair in Serato.

**Architecture:** Analyze each validated snapshot once and install an immutable conflict scope in the existing readiness gate before any synchronization mutations. All writers check their complete target sets; queue draining retains blocked dependency chains while allowing independent work. Publish the same conflict analysis in a dedicated repair screen.

**Tech Stack:** Swift, SwiftUI/AppKit, GRDB/SQLite, existing Rust Serato TLV parser and UniFFI bridge. No new dependency or database schema.

**Spec:** [Approved design](../specs/2026-10-11-unicode-sync-conflicts-design.md).

## Global Constraints

- All state-changing domain work uses the existing OperationEngine mutation/event path; no new repair mutation.
- No automatic removal, Unicode rewriting, SQLite consolidation, or metadata choice.
- No disclosure triangles, expandable rows, or hidden detail sections.
- Original path representations require byte-backed identity; Swift String equality is canonically equivalent.
- Conflicted records remain presence evidence. Exclusion never implies retirement.
- Global source/lifecycle failures remain fatal; per-file conflicts remain visible and isolated.
- Conflicts are session-scoped; startup authorization begins closed. Retry retains stale read-only diagnostics until validated replacement.
- Preserve V2, Subcrates and SmartCrates, including opaque fields and repeated records.
- Use a deterministic 30,000-record fixture with a small conflict set.
- Target under 100 ms of analysis and no new main-actor segment above 50 ms on the reference Mac. Navigation must respond within 500 ms during the conflict-analysis/diagnostic phase.
- No owner-library access in tests and no dev server. Use isolated Test configuration, real temporary fixtures, and injected true boundaries only.
- Extend existing behavior tests; do not add tests for constants, copy, trivial helpers or refactoring. Format changed sources before committing.

## Review Focus

1. A canonically equal String key collapses raw evidence: Task 1 asserts UTF-8 inequality, occurrence count and metadata preservation.
2. An apparently unrelated operation touches a blocked shared recording or destination: Task 2 exercises complete write targets and checks again inside commits.
3. Filtering a duplicate out of the saved snapshot causes retirement: Task 3 proves protected file state and event counts stay unchanged while an unrelated row reconciles.
4. A blocked head or keeper starves or reorders a queue: Task 4 exercises independent later work, dependent tails, retained intent and repair retry.
5. A pre-conflict decode or authorization completes after refresh: Tasks 3 and 5 exercise generation changes, rejected persistence and unaffected worker progress.

## Execution boundary and checks

Worktree: `/Users/benny/.codex/worktrees/e3c6/crate-agent`, branch `fix/unicode-sync-conflicts`.
Product baseline: `d7eac91193c9c72b3f1fa0d0de5fb2549b73a967`.
Baseline evidence from the preceding fix: 706 Swift tests, 15 existing skips, zero failures; 82 Rust tests and Clippy passed. Do not repeat a baseline suite merely for planning.

Keep this as one PR: the safety changes are coupled and partial synchronization must not ship before all guards and consumers are wired. Commits below are reviewable internal boundaries, not separately deployable releases.

Use the existing generated Rust artifacts when Rust production code is unchanged. Verify the UDL/Rust source matches main before copying ignored `CrateAgent/Generated` and `build-output` library/header/module files from the main checkout. Rebuild with `make build-rust` if production Rust or the FFI surface changes. Never copy application data.

Generate the Xcode project with `xcodegen generate`. Use one serial Xcode build at a time, reusing `/Users/benny/dev/crate-agent/build-output/DerivedData` to retain dependency compilation between worktrees. Check that no other build owns that directory before using it. The focused command template is:

```sh
xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent -configuration Test \
  -derivedDataPath /Users/benny/dev/crate-agent/build-output/DerivedData \
  -only-testing:CrateAgentTests/SeratoConflictAnalysisTests test
```

Replace the `-only-testing` value with the owning suite named below; use multiple selectors in one run for coupled changes. Run a failing test before the behavior change, then the owning checks once green. Broaden/repeat only for a real change, failure, or unresolved concern.

## File boundaries

Create these focused units; avoid growing OperationEngine with presentation or Unicode-formatting logic:

- `Models/SeratoPathConflict.swift`: immutable occurrence, diagnostic, scope and target values.
- `Services/SeratoConflictAnalyzer.swift`: snapshot grouping, indexed alias closure, filesystem diagnostics.
- `Services/SeratoConflictTargets.swift`: exhaustive mutation/write-to-target projection using current database rows.
- `Services/SeratoConflictQueue.swift`: conflict disposition and dependency overlap mechanics; engine keeps orchestration.
- `ViewModels/SeratoConflictReviewModel.swift`: selection, stale state and explicit repair actions.
- `Views/SeratoConflictReviewView.swift`: bounded list plus visible details.
- `Constants/SeratoConflictMessages.swift`: copy shared by errors, status, rows and repair instructions.

All paths above are under `CrateAgent/`. New behavioral fixtures/tests live under `CrateAgentTests/`; Rust round-trip tests stay beside the existing parser/FFI tests.

### Task 1: Preserve and classify conflicting snapshot occurrences

**Files:** Create `CrateAgent/Models/SeratoPathConflict.swift`, `CrateAgent/Services/SeratoConflictAnalyzer.swift`, `CrateAgentTests/SeratoConflictAnalysisTests.swift`. Extend `CrateAgentTests/Support/SeratoRemovalFixture.swift` only for reusable raw-record fixture encoding.

**Interfaces:** Consumes existing `SeratoMembershipSnapshot`, `FileRecord` identity projections and `SeratoPath.normalized`. Produces these immutable contracts:

```swift
struct ConflictPhysicalIdentity: Hashable, Sendable {
    let volumeID: String
    let inode: UInt64
}
struct SeratoConflictTarget: Sendable {
    var fileIDs: Set<Int64> = []
    var paths: [String] = []
    var physicalIdentities: Set<ConflictPhysicalIdentity> = []
    var sharedTrackIDs: Set<Int64> = []
}
struct SeratoConflictScope: Sendable {
    let fileIDs: Set<Int64>
    let normalizedPaths: Set<String>
    let physicalIdentities: Set<ConflictPhysicalIdentity>
    let sharedTrackIDs: Set<Int64>
    func conflictingPath(for target: SeratoConflictTarget) -> String?
}
enum ConflictPathObservation: Sendable {
    case existing(ConflictPhysicalIdentity)
    case missing
    case inaccessible
    case offline
    case unknown
    case failed(String)
}
struct SeratoConflictOccurrence: Identifiable, Sendable {
    let id: Int // Original snapshot occurrence index, not String equality.
    let record: SeratoTrackRecord
    let rawPathBytes: Data
    let observation: ConflictPathObservation
}
struct SeratoPathConflict: Identifiable, Sendable {
    let id: String // Normalized grouping path.
    let occurrences: [SeratoConflictOccurrence]
    let fileIDs: Set<Int64>
}
struct SeratoConflictAnalysis: Sendable {
    let libraryID: String
    let generation: UInt64
    let conflicts: [SeratoPathConflict]
    let scope: SeratoConflictScope
}
```

`SeratoConflictAnalyzer.analyze(snapshot:files:) async throws -> SeratoConflictAnalysis` is the production entry point. Provide `init(inspect: @escaping @Sendable (String) throws -> ConflictPathObservation)` for the filesystem boundary; default inspection uses stat/access and established volume rules. Expose `init()` for normal construction. `SeratoConflictScope.conflictingPath` returns a stable, user-identifiable conflict path for any overlapping target; retain the association from protected IDs/physical identities/track IDs back to group paths internally.

- [ ] Add a failing analyzer test using the real snapshot reader and one temporary fixture. Encode two records with literal NFC/NFD strings, distinct metadata, plus an unrelated record. Preserve the existing TLV header and add per-record metadata/opaque fields with `SeratoTestEncoding.record`.

```swift
let composed = "Music/Caf\u{00E9}.mp3"
let decomposed = "Music/Cafe\u{0301}.mp3"
XCTAssertEqual(composed, decomposed)
XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
try fixture.save(paths: [composed, decomposed, "Music/Other.mp3"])
let snapshot = try await fixture.reader.read()
let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: [])
XCTAssertEqual(analysis.conflicts.count, 1)
XCTAssertEqual(analysis.conflicts.first?.occurrences.map(\.rawPathBytes),
               [Data(composed.utf8), Data(decomposed.utf8)])
```

- [ ] Add cases through that public analyzer for zero/one/two successful distinct physical observations, both spellings resolving to one inode, inspection failure, and repeated identical raw records. Use a fake filesystem probe for normalization-sensitive cases the host APFS cannot represent. Keep the normal real-file case; never infer two files from two successful spellings.
- [ ] Run `SeratoConflictAnalysisTests` and observe the missing implementation failure.
- [ ] Implement grouping off-main: retain indexed occurrence bytes first, group by normalized path, diagnose groups with count > 1 only. Preserve all occurrences even when projected metadata agrees. Build indexed alias closure by normalized path and verified volume/inode; include linked track IDs only as protection against shared-row writes, not as a reason to mutate other encodings. For unknown associations, keep the existing ambiguity failure. Do not collect full hashes for every library row or decode fingerprint blobs.
- [ ] Run the owning tests, format changed Swift files, check diff, and commit `Classify Serato path conflicts without losing raw occurrences`.

### Task 2: Enforce conflict scope at mutation and I/O boundaries

**Files:** Create `CrateAgent/Services/SeratoConflictTargets.swift`, `CrateAgent/Constants/SeratoConflictMessages.swift`. Modify `LibrarySyncReadiness.swift`, `OperationEngine.swift`, `SeratoWriteEligibility.swift`, and `FileProcessingEligibility.swift` in `CrateAgent/Services/`. Extend `CrateAgentTests/OperationEngineApplyBatchTests.swift`, `MusicBrainzMutationTests.swift`, and `SeratoLibrarySyncSessionTests.swift` at the public boundary each already owns.

**Interfaces:** Consumes Task 1 values. Add:

```swift
// LibrarySyncReadiness
func install(_ scope: SeratoConflictScope, for authorization: Authorization) throws
func requireUnconflicted(_ target: SeratoConflictTarget) throws
func conflictPath(for target: SeratoConflictTarget) -> String?
// LibrarySyncReadiness.Authorization
func check(target: SeratoConflictTarget) throws
// SeratoConflictTargets
static func mutation(_ mutation: TrackMutation, in database: GRDB.Database) throws -> SeratoConflictTarget
static func write(_ write: GuardedSeratoWrite, in database: GRDB.Database) throws -> SeratoConflictTarget
// New distinct LocalizedError, separate from LibrarySyncReadinessError:
struct SeratoPathConflictError: LocalizedError { let path: String }
```

`install` accepts only this gate's current, not-yet-ready epoch. `invalidate` closes global readiness but retains the prior scope. A new analyzed empty scope clears exclusions only inside a validated replacement epoch. `check(target:)` checks global readiness/epoch and conflict overlap under one lock. `requireUnconflicted` is scope-only for authorized synchronization observations and drain paths; it never grants readiness.

- [ ] Extend public engine tests to install a scope, attempt a direct mutation, and verify both the indexed row and event count remain unchanged. Add a table of actual mutation cases from the current exhaustive switch, including index/import, observations and Serato-authoritative metadata cases whose `processingFileID` is nil. Do not rely on `processingFileID` alone.
- [ ] Exercise a rename whose destination is blocked, a duplicate cleanup whose keeper is blocked, an inverse/historical re-sync referencing an old blocked path, and a MusicBrainz shared-track update affecting protected file state. Cover these through existing owning suites, rather than testing the projection helper separately.
- [ ] Run the affected suites red. Implement an exhaustive `TrackMutation` and `SeratoPendingWrite` projection: current rows, payload old/new/reference paths, keeper identities, inverse payloads and actually written shared track IDs. Unknown new cases must require a compiler-visible decision, not default to an empty target.
- [ ] Add checks before and after serialized transaction bodies and at the final external I/O boundary. Resolve target rows inside the same transaction. Apply the scope-only check to observations and explicit import that legitimately bypass normal readiness; preserve all existing snapshot and physical ownership guards.

```swift
let target = try SeratoConflictTargets.mutation(mutation, in: database)
try readiness?.requireUnconflicted(target)
try authorization?.check()
// Execute the existing mutation/event primitive here, with no parallel writer.
try readiness?.requireUnconflicted(target)
try authorization?.check()
```

- [ ] Audit these concrete engine paths: both `apply` overloads, `executeBatch`, `applyFilesystemObservations`, `applyObservedBatch`, `advanceDuplicateCleanup`, `undoBatch`, `resyncSeratoForBatch`, `performExternalWrite`, and batched physical renames. Ensure pre-write and commit-time target checking agree; a scope change during a writer transaction rolls it back. Add the corresponding controlled-invalidation assertion to the existing transaction test.
- [ ] Run owning checks green, format, diff-check, commit `Guard complete mutation targets against Serato path conflicts`.

### Task 3: Reconcile unaffected entries and publish a coherent conflict state

**Files:** Modify `CrateAgent/Services/SeratoLibrarySyncSession.swift`, `SeratoMembershipReconciler.swift`, `LibraryScanner.swift`, `SeratoMembershipSnapshot.swift`; extend `CrateAgentTests/SeratoLibrarySyncSessionTests.swift` and `SeratoMembershipReconcilerTests.swift`.

**Interfaces:** Consume Tasks 1–2. Extend the existing methods with an optional analysis parameter for compatibility with direct fixture callers:

```swift
func reconcile(_ snapshot: SeratoMembershipSnapshot,
               analysis: SeratoConflictAnalysis? = nil) async throws -> ReconciliationSummary
func scan(snapshot: SeratoMembershipSnapshot, reader: SeratoMembershipSnapshotReader,
          analysis: SeratoConflictAnalysis? = nil,
          progress: ProgressHandler? = nil) async throws -> ScanResult
```

When omitted, derive analysis before mutation using the same analyzer. Reject a supplied analysis with mismatched library/generation. Add `pathConflictCount` and `conflictBlockedWriteCount` (default zero) to `ReconciliationSummary`; retain `State.ready(summary)` for existing callers. The session publishes `conflicts: [SeratoPathConflict]` and `conflictsAreStale: Bool` separately to avoid requiring FFI records to be Equatable. Both are read-only outside the session.

- [ ] Extend the session fixture with an NFC/NFD duplicate referring to an indexed file and an unrelated file absent from V2. Assert the unrelated file retires, the protected row remains byte-for-byte unchanged in persisted columns with no new events for its ID, and the session reaches ready with one conflict.
- [ ] Run the session/reconciler suites red. In `run`, capture the current epoch, analyze the full snapshot and identity projections off-main, validate again, install scope, then reconcile/scan. Never remove conflict paths from saved presence evidence. Exclude protected IDs, aliases and move candidates before dictionaries or move matching can choose a winner. Keep unsupported unrelated indexed ambiguity fatal.
The session orchestration uses one analysis for both consumers:

```swift
let authorization = readiness.prepareDrain()
let snapshot = try await reader.read()
let files = try await scanner.identityProjectionsForConflictAnalysis()
let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: files)
try await reader.validate(snapshot)
try readiness.install(analysis.scope, for: authorization)
var summary = try await reconciler.reconcile(snapshot, analysis: analysis)
_ = try await scanner.scan(snapshot: snapshot, reader: reader, analysis: analysis)
summary.pathConflictCount = analysis.conflicts.count
```

Add `LibraryScanner.identityProjectionsForConflictAnalysis() async throws -> [FileRecord]`
as a thin call to its injected database's existing `FileRecord.loadIdentityProjections`;
include track IDs in that lightweight projection if absent. Pass the buffered
progress callback in the real session. Continue into the existing validated drain,
source recheck and ready publication rather than treating this excerpt as the end
of synchronization.

- [ ] Preserve stale details while `requestSync`, cancellation or waiting closes the gate. Publish new conflict details only after source validation. If draining changes V2, re-read, re-analyze, re-install scope in a closed epoch, and validate again before readiness or fingerprinting resumes. A queued write cannot leave protection based on a superseded snapshot.
- [ ] Extend existing cancellation/source-corruption/Serato-transition tests with one conflict, proving stale completion cannot clear scope or publish readiness. Verify a repair snapshot with only one chosen record clears the count only after successful validation. Direct scanner entry must also respect scope rather than bypass the session.
- [ ] Run owning checks green, format, diff-check, commit `Continue synchronization around isolated Serato path conflicts`.

### Task 4: Retain blocked queue chains and preserve Serato records

**Files:** Create `CrateAgent/Services/SeratoConflictQueue.swift`. Modify `OperationEngine.swift`, `SeratoWriteEligibility.swift` and the `ResyncOutcome` declaration in `OperationEngine.swift`. Extend queue scenarios in `CrateAgentTests/SeratoLibrarySyncSessionTests.swift`, `OperationEnginePartialFailureTests.swift`; add round-trip tests in `rust-core/src/serato.rs` and `rust-core/src/ffi.rs`.

**Interfaces:** Consume `SeratoConflictTargets.write` and gate scope checks. Add `conflictBlockedCount: Int = 0` to `ResyncOutcome`; its unit is distinct queued event IDs, matching queued/applied counts. The new queue unit supplies:

```swift
enum SeratoConflictQueueDisposition { case eligible, blocked, superseded }
struct SeratoQueueDependency: Sendable {
    let fileIDs: Set<Int64>
    let eventIDs: Set<Int64>
    let normalizedPaths: Set<String>
    let physicalIdentities: Set<ConflictPhysicalIdentity>
    let sharedTrackIDs: Set<Int64>
    func intersects(_ other: SeratoQueueDependency) -> Bool
}
```

Build dependencies from Task 2 targets plus keeper/cleanup relationships. Use the same overlap helper for ordinary drain and explicit historical replay; leave their orchestration separate.

- [ ] Extend the existing queue fixture: queue blocked file A, a dependent later A/keeper step, and independent B. Install the conflict scope and drain. Assert only B's bytes/event complete, A's entries remain in order, no false supersession occurs, and repeated drain returns promptly. Repair A, retry with current revision/baseline validation, and prove stale intent is superseded only by the existing rules.
- [ ] Run those tests red. Replace head-only draining with a bounded pass over the entries present at pass start. Track blocked dependencies; retain overlapping later entries without executing them. Remove completed or genuinely superseded entries by stable event/write identity, preserving retained order. Never rotate indefinitely or mark a blocked duplicate-cleanup step failed merely because it waits for repair. Include the retained count in the session summary.
- [ ] Audit `applyConsecutiveSeratoWrites` and batching: do not coalesce through a blocked chain or lose raw references. Test mid-pass source invalidation, genuine external failure, and Serato launch through existing lifecycle tests; real failures still abort visibly.
- [ ] Extend Rust round-trip fixtures with NFC/NFD duplicate otrk entries, differing metadata and unknown TLVs, plus one unrelated editable record. Apply existing add/update/remove/rename FFI operations to the unrelated target across V2, `.crate`, and `.scrate`. Assert protected raw record byte sequences and multiplicity are unchanged, and the intended unrelated change occurred. Use literal expected original record bytes, not the serializer's output as its own oracle.

```rust
assert_ne!(composed_path.as_bytes(), decomposed_path.as_bytes());
assert_eq!(protected_records_after, protected_records_before);
assert_eq!(unrelated_target_count_after, 1);
```

The record collections in the second assertion are raw TLV slices selected by the test's original occurrence positions/tags, not canonical-path HashMap values. Construct the fixtures with existing TLV test utilities in `serato.rs`/`ffi.rs`; do not add a second parser. If a production writer loses unrelated records, fix the preserving rewrite now and rebuild the Rust library before Swift validation. If a writer cannot safely preserve the group, return an explicit conflict-blocked disposition for that operation and expose the retained reason.
- [ ] Run `cargo test --manifest-path rust-core/Cargo.toml --workspace` plus owning Swift queue tests, format both languages, diff-check, commit `Drain independent writes while retaining conflict-blocked intent`.

### Task 5: Keep unaffected processing live and protected results out of persistence

**Files:** Modify `CrateAgent/Services/FingerprintWorker.swift`, `FingerprintPersistence.swift`, `AutoTaggerService.swift`, `FilesystemSyncCoordinator.swift`, `FilesystemSyncBatchHandler.swift`, `ImportCoordinator.swift`, and eligibility-consuming preview/search services (`LibraryOrganizer.swift`, `LibraryHygiene.swift`, `AutoTagFileSearch.swift`, `OrganizePreviewSnapshot.swift`). Modify `CrateAgent/ViewModels/OrganizePreviewModel.swift` and existing row adapters only where needed to expose the reason. Extend `CrateAgentTests/FileEligibilityIntegrationTests.swift`, `SeratoLibrarySyncSessionTests.swift`, and existing import recovery tests.

**Interfaces:** Consume Tasks 1–4. Keep `FileProcessingEligibility`'s membership/availability semantics intact; conflict state comes from the injected readiness gate. Call `gate.conflictPath(for:)` for presentation and scope checks for authorization. Extend `FingerprintPersistence.withAuthorization` with `targets: [SeratoConflictTarget] = []`, checking every supplied target before and after its existing transaction closure. Update every production caller; the default is only compatibility for fixtures with no conflict gate.

Preserve transaction rollback on invalidation with the following shared wrapper;
callers supply the rows actually being written, including propagated twin results:

```swift
static func withAuthorization<Result>(
    _ authorization: LibrarySyncReadiness.Authorization?,
    targets: [SeratoConflictTarget] = [],
    perform body: () throws -> Result
) throws -> Result {
    func validate() throws {
        try authorization?.check()
        for target in targets {
            try authorization?.check(target: target)
        }
    }
    try validate()
    let result = try body()
    try validate()
    return result
}
```

- [ ] Extend the suspended fingerprint fixture: decode begins, sync introduces a conflict, decode completes. Assert no fingerprint/basis/status result commits for the blocked ID and it stays retryable. In the same fixture, an independent pending file reaches done. Cover representative, byte-twin propagation and on-demand Auto-Tag persistence through the shared existing writer rather than duplicating private-helper tests.
- [ ] Run owning tests red. Filter protected files before dispatching work and recheck current targets at persistence. Iterate eligible candidates beyond blocked leading rows; do not repeatedly fetch only a blocked first page or falsely report a drained queue. Keep global epoch invalidation distinct from a single file's conflict. Preserve cancellation and visible infrastructure errors.
- [ ] Route per-file Auto-Tag/import/preview failures to existing per-row result/progress channels with a repair reason. Reject new imports targeting protected paths before allocation or filesystem changes. Batch preflight includes all selected IDs and possible destinations; exclusion from a preview is explained, not silent. A stale preview still fails safely at the engine boundary.
- [ ] In filesystem handling, retain conflict-blocked observations as pending/reconciliation-required work without marking unrelated paths globally failed or acknowledging blocked observations as applied. Reuse existing checkpoint retention; track blocked paths separately from terminal infrastructure failure. On repair, replay through current identity validation. Extend the existing filesystem checkpoint test with one blocked path plus independent work, asserting no event loss or false checkpoint completion.
- [ ] Audit every `FingerprintPersistence.withAuthorization`, `readiness.capture`, and explicit import call with `rg`; record the call-site checklist in the execution ledger. Add no broad refactor to worker scheduling.
- [ ] Run owning checks green, format, diff-check, commit `Keep unrelated workers and previews usable during path conflicts`.

### Task 6: Expose guided repair and verify the complete user journey

**Files:** Create `CrateAgent/ViewModels/SeratoConflictReviewModel.swift`, `CrateAgent/Views/SeratoConflictReviewView.swift`, `CrateAgentTests/SeratoConflictPresentationTests.swift`. Modify `CrateAgent/Constants/SeratoConflictMessages.swift`, `CrateAgent/App/AppServices.swift`, `CrateAgent/Views/MainWindowView.swift`, `MenuBarStatusView.swift`, `Components/AppPresentation.swift`, and Library row/action presentation. Update `README.md`, `docs/serato-membership-reconciliation.md`, `docs/testing.md`.

**Interfaces:** Consume session conflicts/staleness and summary counts. Add a main-window detail navigation destination for conflicts, not an accordion. Route menu-bar Review conflicts through the existing main-window activation mechanism and a services-owned navigation request. Keep ordinary sidebar sections stable. The model takes closures for explicit native actions:

```swift
@MainActor
final class SeratoConflictReviewModel: ObservableObject {
    @Published var selectedConflictID: String?
    @Published private(set) var actionError: String?
    // Initializer stores these closures and the session's observed conflict state.
    // Native adapters are supplied by AppServices; tests inject action boundaries.
    // copyDetails: (String) throws -> Void
    // revealFile: (String) async throws -> Void
    // openSerato: () async throws -> Void
    // retrySync: () -> Void
}
```

Declare the initializer as `init(session: SeratoLibrarySyncSession, copyDetails: @escaping (String) throws -> Void, revealFile: @escaping (String) async throws -> Void, openSerato: @escaping () async throws -> Void, retrySync: @escaping () -> Void)`. It publishes current groups/staleness from the session; selection falls back to the first remaining conflict only as navigation, never as a mutation choice.

- [ ] Add a presentation integration test mounting the actual SwiftUI conflict screen with synthetic session evidence. Assert accessible Review conflicts navigation, both raw spellings/Unicode details, differing metadata, stale/inspection-error states, and action failure visibility. Test actual action routing once at injected native boundaries; do not snapshot wording constants.
- [ ] Run presentation checks red. Implement an amber ready status with conflict and blocked-event counts in main and menu bar, retaining global failure styling. Always show the selected conflict's data and repair steps. Bound list rendering with native/lazy rows; do not construct all detail views. The Library context action keeps clicked-ID semantics and explains blocked mutation actions.
- [ ] Implement explicit Copy details, Show in Finder, Open Serato and Retry Sync. Reinspect the selected raw path before Finder reveal; missing/access failures appear in `actionError`. Use the existing watchdog's supported Serato bundle IDs when locating the app; failed launch is visible. Never launch Serato automatically. Waiting/retry state follows the existing lifecycle. Copy/export only occurs on the user's click.
- [ ] Guidance distinguishes no verified live file, aliases of one file, distinct files, and unknown/inaccessible cases. Preserve metadata/crate choices for the owner, warn within the repair instructions against deleting audio, and require saved/closed Serato before validating success. Keep counts and diagnostics until the repaired snapshot is proven current.
- [ ] Add the production-size case to the existing analysis/session fixture using one module-owned temporary WAL database. Generate 30,000 lightweight records and a small conflict set; measure analysis separately, heartbeat delay and hosted navigation response, and count diagnostic probes. Assert unrelated reconciliation and blocked state invariants. The diagnostic count scales with conflicted spellings, not the full library. Record XCTest attachments; do not weaken assertions or rerun solely to select a faster timing.
- [ ] Inspect light/dark, comfortable/compact render artifacts. For the owner-running app smoke check, describe the exact path: Review conflicts, inspect both spellings, copy details, reveal a verified file, launch Serato explicitly, save/close, retry, confirm counts clear. Do not start a dev server or access the owner's Serato/audio files from automated tests.
- [ ] Update README usage with the amber status/repair entry point, reconciliation docs with scope/queue/generation semantics, and testing docs with the fixture command and metric meanings. Keep README below 16,000 bytes and preserve its opening thesis.
- [ ] Format changed sources, then run final serial Swift verification and Rust checks:

```sh
make test-swift DERIVED_DATA_PATH=/Users/benny/dev/crate-agent/build-output/DerivedData
CARGO_TARGET_DIR=/Users/benny/dev/crate-agent/rust-core/target cargo test --manifest-path rust-core/Cargo.toml --workspace
CARGO_TARGET_DIR=/Users/benny/dev/crate-agent/rust-core/target cargo clippy --manifest-path rust-core/Cargo.toml --workspace -- -D warnings
cargo fmt --manifest-path rust-core/Cargo.toml --all --check
wc -c README.md
git diff --check
```

- [ ] Commit `Add guided Serato path-conflict review and recovery`. Run the review workflow required by the chosen execution method against product baseline `d7eac91193c9c72b3f1fa0d0de5fb2549b73a967`. Fix confirmed findings and verify affected behavior. Push and open one PR closing https://github.com/aud-eos/crate-agent/issues/130 with test counts, existing skips, timing evidence, queue semantics and limitations. Do not merge without a new explicit request; keep this worktree while the PR is open.

## Plan self-review

Coverage: occurrence evidence/diagnostics (1), complete target protection (2), partial sync and stale lifecycle (3), preserved queues and Rust round trips (4), worker/import/filesystem/preview consumers (5), repair navigation/actions/production fixture/docs/final verification (6). All five Review Focus conditions have owning behavioral tests. Dependencies run 1 → 2 → 3 → 4 → 5 → 6; later tasks use the signatures defined above. No schema change, new dependency, automatic repair, or second parser is planned. Guided repair remains the approved scope. Owner approval of this plan and execution method precedes implementation.
