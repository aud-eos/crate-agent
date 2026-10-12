# Paged Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Browse and deliberately select all matching Library files through a continuous native scrollbar while retaining only a bounded window of decoded rows.

**Architecture:** An immutable database snapshot backs each query generation. A generic controller schedules bounded pages and delegates captured selection to a provider; a reusable AppKit table renders indexed rows and placeholders. The Library adapter supplies SQL, revision reconciliation, columns, and existing single-file actions.

**Tech Stack:** Swift 5.10, macOS 14+, SwiftUI, AppKit NSTableView, existing GRDB 6 / SQLite WAL, XCTest; no new dependencies.

**Spec:** [Approved design](../specs/2026-10-11-paged-library-design.md), approved by the owner on 2026-10-11; implements GitHub #134 after #146 / PR #154.

## Global Constraints

- Start with 200 rows per page and at most five cached pages (1,000 decoded rows).
- Count and page reads in a generation use one read snapshot, not independent reads of a changing database.
- Do not keep a library read transaction alive solely to remember a long-lived selection.
- Initially nothing is selected.
- Search/filter/sort changes preserve selections, show hidden counts, and do not rewrite their captured scope.
- Never publish a partial capture as successful Select All.
- This work adds no Library bulk mutation action.
- Target under 100 ms for rendering placeholders and under 50 ms for main-thread work on the fixture; report measured asynchronous page latency separately.
- Do not access the owner's library or start a dev server.
- Preserve the no-disclosure UI rule throughout.
- Use descriptive identifiers, shared constants for repeated strings, and the existing isolated Test configuration. Domain writes still go through OperationEngine; ephemeral selection storage contains presentation state only.
- Read README.md, design-plan.md, AGENTS.md, and the approved spec before execution. Read the silent-failures guide before implementing retry paths. Do not change dependency pins.

## Review Focus

1. A cancelled old page finishes after a distant jump or query change: neither stale rows nor stale errors can publish (Task 1).
2. An existing nonmatching file becomes a match after Select All, or a selected file changes membership revision: no implicit additions or identity substitution (Task 4).
3. A focused placeholder loads after the user changes query; a selected anchor disappears: no deferred action or selection moves to a different file (Tasks 2 and 4).
4. A selection capture fails halfway through or Clear occurs while it is running: the last committed selection survives failure, Clear wins over late work, and Retry is visible (Tasks 1 and 4).
5. Metadata changes outside the current page without changing count, or a viewport exceeds the default cache window: refresh ordering remains correct and memory stays within the declared adaptive bound (Tasks 1 and 3).

---

## Delivery and file map

Use the existing `feat/paged-library` branch in `/Users/benny/.codex/worktrees/5611/crate-agent`. Deliver one PR closing #134 with three reviewable sections/commit groups: core (Task 1), native bridge (Task 2), Library adoption (Tasks 3–5). These depend on one another, so separate dependent PRs would add integration gates without independently shipping the requested behavior. Keep Library's existing UI until all adoption and performance checks pass.

| File | Responsibility |
| --- | --- |
| `CrateAgent/Models/Paging/PagedQuery.swift` | Generic snapshot, identity, selection-provider contracts and value types |
| `CrateAgent/Models/Paging/PagedResultsController.swift` | Main-actor generation, viewport/cache/request scheduling and published state |
| `CrateAgent/Models/Paging/PagedSelectionController.swift` | Serialized selection intent, counts, progress and error state |
| `CrateAgent/Views/Components/PagedTable.swift` | Generic NSViewRepresentable, native coordinator and viewport notifications |
| `CrateAgent/Views/Components/PagedNSTableView.swift` | Keyboard, context-click and logical selection drawing without enumerating all indices |
| `CrateAgent/Services/LibraryPaging/LibraryBrowseQuery.swift` | Immutable Library filter/search/sort and SQL ordering |
| `CrateAgent/Services/LibraryPaging/LibraryPagedSnapshot.swift` | GRDB snapshot reads, bounded identities, anchor lookup |
| `CrateAgent/Services/LibraryPaging/LibraryBrowseObservation.swift` | Relevant-column invalidation without fetching all rows |
| `CrateAgent/Services/LibraryPaging/LibrarySelectionStore.swift` | Ephemeral SQLite capture, explicit identities/exclusions, atomic updates and reconciliation |
| `CrateAgent/Models/LibraryBrowserModel.swift` | Library query/refresh lifecycle, controller composition and stable-ID actions |
| `CrateAgent/Views/LibraryBrowserColumns.swift` | Native cell presentation and Library column descriptors |
| `CrateAgent/Views/LibraryBrowserView.swift` | Search/filter/selection controls, table host, drop import and existing sheets |
| `CrateAgent/Services/LibraryStatusBrowse.swift` | Retained small synchronous browse API delegates to shared SQL builder |
| `CrateAgent/Database/Database.swift` | Internal explicit-path WAL factory shared by production and synthetic fixtures |
| `CrateAgentTests/Support/PagedQueryFixture.swift` | Second row type and controllable asynchronous query/provider boundary |
| `CrateAgentTests/Support/PagedLibraryFixture.swift` | One deterministic 30,000-row temporary WAL database per test class |
| `CrateAgentTests/PagedResultsControllerTests.swift` | Generic cache, generation, error and selection intent behavior |
| `CrateAgentTests/PagedTableTests.swift` | Native keyboard, placeholders, selection and context targeting |
| `CrateAgentTests/LibraryPagingTests.swift` | Real snapshot/search/sort/observation/selection integration and measured performance |
| Existing rendering/status/eligibility tests | Adapt existing coverage to the new entry points; retain domain assertions |
| `README.md`, `docs/list-controls.md`, `docs/testing.md` | Usage contract and reproducible performance checks |

### Task 1: Generic bounded paging and selection intent

**Files:** Create the three `Models/Paging/` files, `Support/PagedQueryFixture.swift`, and `PagedResultsControllerTests.swift` from the map.

**Interfaces:** Define the following public-to-module contracts in `PagedQuery.swift`. A selection revision is an opaque provider-supplied Int64; the generic layer never interprets it. `Row.ID` must be Hashable and Sendable.

```swift
struct PagedIdentity<Identifier: Hashable & Sendable>: Hashable, Sendable {
    let id: Identifier
    let revision: Int64
}

protocol PagedQuerySnapshot: Sendable {
    associatedtype Row: Identifiable & Sendable where Row.ID: Sendable
    associatedtype Signature: Hashable & Sendable
    var signature: Signature { get }
    func count() async throws -> Int
    func rows(in range: Range<Int>) async throws -> [Row]
    func index(of id: Row.ID) async throws -> Int?
    func identities(after id: Row.ID?, limit: Int) async throws -> [PagedIdentity<Row.ID>]
    func identity(for row: Row) -> PagedIdentity<Row.ID>
}

struct PagedSelectionSummary: Equatable, Sendable {
    let total: Int
    let inScope: Int
    let scopeCount: Int
    let removed: Int
    var hidden: Int { total - inScope }
}

protocol PagedSelectionProvider: Sendable {
    associatedtype Snapshot: PagedQuerySnapshot
    func set(_ identities: [PagedIdentity<Snapshot.Row.ID>], selected: Bool) async throws
    func setScope(_ snapshot: Snapshot, selected: Bool) async throws
    func setRange(_ range: Range<Int>, in snapshot: Snapshot, selected: Bool) async throws
    func selectedIDs(in identities: [PagedIdentity<Snapshot.Row.ID>]) async throws -> Set<Snapshot.Row.ID>
    func summary(in snapshot: Snapshot) async throws -> PagedSelectionSummary
    func reconcile() async throws -> Int
    func clear() async throws
    func close() async
}
```

`identities(after:limit:)` is provider-defined stable keyset order, independent of display order. An entire snapshot is immutable and safe to share; serial database access belongs inside the provider. Calls to `rows` validate ranges and never return a partial successful page within the advertised count.

The main-actor `PagedResultsController<Snapshot: PagedQuerySnapshot>` is ObservableObject and exposes `totalCount: Int`, `generation: UInt64`, `effectivePageSize: Int`, `cacheLimit: Int`, `cachedRowCount: Int`, `peakCachedRowCount: Int`, `decodedRowCount: Int`, `changedRows: IndexSet`, `error: String?`, `isLoading: Bool`, and `snapshot: Snapshot?` (read-only). Methods: `open(_ snapshot: Snapshot, anchorID: Snapshot.Row.ID? = nil) async`, `setViewport(_ range: Range<Int>)`, `row(at index: Int) -> Snapshot.Row?`, `retry()`, and `stop()`. Publish a separate `viewportAnchor: Int?` to request native scroll restoration.

`PagedSelectionController<Provider: PagedSelectionProvider>` is ObservableObject, owns a provider, and exposes read-only `summary: PagedSelectionSummary?`, `visibleSelectedIDs: Set<Provider.Snapshot.Row.ID>`, `isBusy: Bool`, and `error: String?`. Methods: `set(_:selected:)`, `setScope(_:selected:)`, `setRange(_:in:selected:)`, `updateScope(_:visibleIdentities:)`, `reconcile(in:)`, `clear()`, `retry()`, and `stop()`, with identity and snapshot types taken from Provider. Provider mutations run in intent order; Clear/stop invalidate pending results and cancel pending captures before clearing/closing. Keep all identity scans off the main actor. Do not retain a snapshot in completed selection state.

- [ ] Create a second row type and actor fixture with gated completions, recording requested ranges and allowing count/page/capture errors. Use continuations at the query boundary, not sleep-based races. Its constructor is `PagedQueryFixture(rowCount: Int, signature: String)`; it implements PagedQuerySnapshot using `FixtureRow(id: Int, name: String)`, and exposes `releaseAll()`, `failNextPage()`, and `requestedRanges()`. The paired `FixtureSelectionProvider` implements selection using a small real identity dictionary solely in tests.
- [ ] Add the bounded-distant-jump and stale-generation test, plus one table-driven error/retry test. Exercise oversized viewport in the bounded test and capture failure/Clear in a selection-intent test. Representative assertion sequence:

```swift
let source = PagedQueryFixture(rowCount: 30_000, signature: "first")
let controller = PagedResultsController<PagedQueryFixture>()
await controller.open(source)
controller.setViewport(29_950..<30_000)
await source.releaseAll()
// Await published row availability using XCTest expectations, not a fixed delay.
XCTAssertEqual(controller.totalCount, 30_000)
XCTAssertLessThanOrEqual(controller.cachedRowCount, controller.cacheLimit)
XCTAssertLessThanOrEqual(controller.peakCachedRowCount, controller.cacheLimit)
XCTAssertNil(controller.row(at: 0))
```

For the race, switch to a second signature before releasing the first source; assert the second count, row IDs and error state remain unchanged. For capture failure, assert the previous explicit identity remains selected; then Clear during a suspended capture must leave total zero after that capture completes.

- [ ] Prepare the isolated build using existing unchanged Rust artifacts, then run the focused test expecting missing paging types:

```sh
mkdir -p build-output
cp /Users/benny/dev/crate-agent/build-output/libcrate_agent_core.a build-output/
cp -R /Users/benny/dev/crate-agent/CrateAgent/Generated CrateAgent/
xcodegen generate
xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent -configuration Test -derivedDataPath build-output/DerivedData -only-testing:CrateAgentTests/PagedResultsControllerTests test
```

- [ ] Implement the controller cache with page-number keys and a five-page desired window. Use `max(200, (visibleCount + 3) / 4)` for effective page size so an unaligned viewport spans at most five pages; fill remaining slots with adjacent pages. Clamp to valid indices, prioritize visible pages, and allow at most two outstanding requests including cancelled requests that have not completed. Drop queued obsolete work immediately. Evict outside the desired window before admitting results. A page completion must pass both generation and request-token checks:

```swift
guard completedGeneration == generation,
      activeRequests[pageNumber] == requestToken,
      desiredPages.contains(pageNumber)
else { return }
```

Cache eviction and admission happen in one main-actor turn. Changing effective size invalidates page positions. Count errors leave a visible error instead of publishing a fake empty count; page errors retain count and mark the failed range for Retry. Cancellation from obsolete work is not a user error. Publish changed row ranges rather than forcing full-table reload on each page.

- [ ] Implement serialized selection commands with a monotonically increasing intent token, retained failed-command Retry, and separate busy/error state. During unresolved capture or scope counts disable scope-dependent controls; ordinary scrolling continues. Provider commit and UI publication both honor cancellation. Clear awaits cancellation completion before clearing the provider so a late write cannot resurrect selection.
- [ ] Run the focused tests; expect all pass. Format only changed Swift files, run `git diff --check`, then commit `Add bounded paged query and selection controllers`.

### Task 2: Native indexed table with placeholders and stable-ID interaction

**Files:** Create `PagedTable.swift`, `PagedNSTableView.swift`, and `PagedTableTests.swift`; reuse the Task 1 fixture. Leave `VirtualizedPreviewTable.swift` behavior unchanged.

**Interfaces:** Consumes Task 1 controllers. Produces `PagedTable<Snapshot: PagedQuerySnapshot>: NSViewRepresentable` with controller, columns, selected-ID membership, selection callbacks, sort callback, context-menu callback, accessibility label, and row height. Define `PagedTableColumn<Row>` with `identifier: String`, `title: String`, `width: CGFloat`, `makeCell: () -> NSView`, and `updateCell: (NSView, Row?) -> Void`. Nil means placeholder. Callbacks: `onSelect: ([Row], Bool) -> Void`, `onSelectRange: (Range<Int>, Bool) -> Void`, `onSelectAll: () -> Void`, `onSort: (String, Bool) -> Void`, and `contextMenu: (Row.ID) -> NSMenu?`. `isSelected: (Row.ID) -> Bool` reads only bounded visible membership.

- [ ] Add one native interaction test using a real NSWindow and NSTableView: full 30,000 row count before pages resolve, jump to last row, focus an unloaded row, change generation, release old page, verify no selection/action fires. Continue with a loaded row after sort and assert context-click returns its stable ID. Add Shift-range and Command-A checks to the same test, plus deletion/adjacent-focus coverage with the fake query. Do not instantiate owner services.

```swift
XCTAssertEqual(table.numberOfRows, 30_000)
table.scrollRowToVisible(29_999)
table.selectAll(nil)
XCTAssertEqual(selectAllCalls, 1)
XCTAssertTrue(selectedIdentities.isEmpty) // Provider has not completed capture.
XCTAssertLessThan(table.subviews.count, 200)
```

- [ ] Run `xcodebuild` with the Test configuration and `-only-testing:CrateAgentTests/PagedTableTests`; expect missing table types initially.
- [ ] Implement `numberOfRows` from count and reusable cell views from `row(at:)`; return placeholder cells immediately. Observe clip-view bounds changes and call `setViewport` with `rows(in: visibleRect)`. On page publication call `reloadData(forRowIndexes:columnIndexes:)`; change count only on a generation change. Remove observers and stop tasks when dismantled.

```swift
let visibleRows = table.rows(in: table.visibleRect)
if visibleRows.location != NSNotFound {
    controller.setViewport(visibleRows.location..<(visibleRows.location + visibleRows.length))
}
```

- [ ] Preserve AppKit keyboard focus and native click/Command-click/Shift-click semantics, while keeping logical selected identities separate from `selectedRowIndexes`. Draw loaded row selection from `isSelected`; focus alone never implies a batch target. Do not construct an IndexSet of every matched row for Command-A. Shift-range selection invokes the provider with a bounded identity stream for that range, including unloaded rows. A deferred placeholder click stores generation/index/intent; resolve only if all three still match. Cancel it on another interaction or query change. Implement accessible selected/focused state and disabled placeholder actions. Context menus are ordinary existing action menus, not expandable content sections.
- [ ] Rerun native and generic tests, format changed files, and commit `Add native paged table with stable selection and placeholders`.

### Task 3: Snapshot-backed Library query and observation

**Files:** Create `LibraryBrowseQuery.swift`, `LibraryPagedSnapshot.swift`, `LibraryBrowseObservation.swift`, `Support/PagedLibraryFixture.swift`, and `LibraryPagingTests.swift`. Modify `Database.swift`, `LibraryStatusBrowse.swift`, `LibraryBrowserView.swift` SQL helpers, and existing status/eligibility tests that call those helpers.

**Interfaces:** `LibraryBrowseQuery: Hashable, Sendable` stores `filter: LibraryStatusFilter`, `search: String`, `sort: LibraryBrowseSort`. `LibraryBrowseSort` stores a typed column enum and ascending Bool; columns are artist/title/bpm/musicalKey/album/path, with folder mapped to path to preserve behavior. Make LibraryStatusFilter Sendable. `LibraryPagedSnapshot: PagedQuerySnapshot` uses Row = BrowserRow and Signature = LibraryBrowseQuery. Factory: `static func open(pool: DatabasePool, query: LibraryBrowseQuery) async throws -> LibraryPagedSnapshot`. `LibraryBrowseObservation.start(in:onChange:onError:)` accepts the LibraryDatabase and Sendable callbacks and returns `AnyDatabaseCancellable`. Add internal `LibraryDatabase.openWAL(at url: URL) throws -> LibraryDatabase`, which uses existing configuration and migrations; production obtains its existing path before calling it. Reject non-pool writers when opening production paging rather than silently falling back to incoherent reads.

- [ ] Build a class-scoped synthetic WAL fixture with 30,000 active/available files, fixed IDs 1...30,000, repeated artists for tie-breaking, and a unique last-row title. Seed through FileRecord in one transaction; never create audio or access the owner's paths. Tests restore modified rows in teardown, and release snapshots before deleting the fixture directory. Expose `database: LibraryDatabase`, `pool: DatabasePool`, and `query: LibraryBrowseQuery`.
- [ ] Add snapshot consistency/search/sort coverage using that fixture. Read count, mutate the live database, and then read first/last pages from the old snapshot. The old snapshot must stay at 30,000; a new snapshot must reflect the mutation. Ascending/descending tied artist pages must have disjoint IDs with deterministic ID tie-breaks. Reuse existing literal/Unicode search assertions, adding the last-row title to prove full-library reach:

```swift
let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
let originalCount = try await snapshot.count()
XCTAssertEqual(originalCount, 30_000)
let lastPage = try await snapshot.rows(in: 29_800..<30_000)
XCTAssertEqual(lastPage.count, 200)
XCTAssertEqual(Set(lastPage.map(\.id)).count, 200)
```

Add an observer expectation for a metadata-only update outside the initial page without count change. Separately update fingerprint data and assert it does not trigger a presentation refresh. Retain existing availability observation coverage, moving it to the new observer where appropriate rather than duplicating it.

- [ ] Run LibraryPagingTests expecting missing new adapter types.
- [ ] Move whitelisted SQL ordering out of LibraryBrowserView. Share predicate/bound arguments/order between synchronous fetch and snapshot count/pages/identity queries. Preserve ListSearch registration, trimming and literal Unicode matching; append `files.id ASC` to every display order. Do not interpolate user input into SQL. Use `BrowserRow.browserColumnsSQL` only for row pages; identities select only id and membership_revision. Execute GRDB snapshot reads away from MainActor and check cancellation between batches. For anchor lookup use the identical ordering via an indexed/window query returning one position, not a decoded row array:

```sql
SELECT position FROM (
  SELECT files.id, ROW_NUMBER() OVER (ORDER BY COALESCE(files.artist, '') ASC, files.id ASC) - 1 AS position
  FROM files WHERE files.library_membership = 'retired'
) WHERE id = ?
```

This concrete example locates an artist-sorted retired file. Generate its predicate and ordering with the same typed SQL builder used by count and pages, including bound search arguments when present. Snapshot creation and count happen before publishing a generation. Closures finishing cancelled reads may retain the old snapshot temporarily; the controller must drop its own reference immediately on replacement/stop.
- [ ] Observe `files` columns id/path/artist/title/album/bpm/musical_key/library_membership/file_availability/membership_revision with DatabaseRegionObservation. Register before initial snapshot creation so no commit is missed; callbacks only enqueue invalidation. Coalesce bursts with a dirty flag and one running refresh, then refresh again if invalidated during the read. Surface observer failures and retry subscription visibly. Do not use a broad whole-table decode or COUNT-only observation.
- [ ] Run adapter, status, shared-search and eligibility suites. Format and commit `Add consistent Library snapshots and query invalidation`.

### Task 4: Captured Library selection without retaining the library snapshot

**Files:** Create `LibrarySelectionStore.swift`; extend `LibraryPagingTests.swift`. Implement the Task 1 range-selection contract for the Task 2 Shift-range callback using bounded identity-only display-order queries, rather than loading BrowserRow values.

**Interfaces:** `LibrarySelectionStore: PagedSelectionProvider` uses Snapshot = LibraryPagedSnapshot; initialize with `init(database: LibraryDatabase) throws`. It owns a temporary SQLite file/queue on a private serial executor. All external methods are async and never block MainActor. `setScope`/`setRange` copy fixed id/revision membership from the passed snapshot, then release it; live-library `reconcile()` removes deleted or revision-changed identities across all selected scopes. `close()` cancels work, closes the store, and deletes its temporary directory. No production migrations.

- [ ] Add a single integrated sequence: select all from a search snapshot, exclude one visible ID, change filter, assert total/hidden counts, insert a matching file and change an existing nonmatch to match, refresh, and assert neither joins. Change one selected membership_revision, delete another, reconcile, and assert exactly those two drop with notice. Exercise scoped deselection and global clear. Expected counts derive from fixture identities, not from another call to the selection implementation.
- [ ] Add capture cancellation/failure rollback coverage using an injected failing identity stream at the query boundary. Preserve a prior explicit selection, fail the second batch, assert the prior set survives. Suspend a capture, request Clear, resume, assert zero. Reuse generic error-state tests rather than duplicating their UI assertions.
- [ ] Run LibraryPagingTests with the isolated Test host, expecting missing store initially.
- [ ] Implement ephemeral tables for captured members, explicit selections and exclusions, each keyed by id/revision. Build each scope in staging tables using batches of 200 identities ordered by ID. Commit scope union/difference only after the final batch and cancellation check; failure removes staging state. Multiple scopes form a set union, so a file never counts twice. Explicit selection removes its exclusion; scoped deselection only removes current captured scope membership. Clear invalidates outstanding commands before emptying all committed/staged membership.

```sql
CREATE TABLE selected_identity (
    id INTEGER PRIMARY KEY,
    revision INTEGER NOT NULL
);
CREATE TABLE staged_identity (
    id INTEGER PRIMARY KEY,
    revision INTEGER NOT NULL
);
```

Use a normalized effective selected table for bounded visible membership/count queries, alongside capture provenance and exclusions. Never hold a SQLite write transaction across an async suspension: staging batches commit separately; final publication is one short transaction. Scan query identities in bounded batches to compute in-scope counts against the store; cancellation and generation checks protect publication. Reconcile against a fresh library snapshot by streaming sorted identity/revision batches and checking store rows in bounded batches; selecting a new query must not redefine captured membership. Temporary snapshots for reconciliation/counting end when those operations finish. Capture progress can be indeterminate busy state with a visible label; failures preserve the committed selection and offer Retry.
- [ ] Verify large selection capture does not decode BrowserRow or increase its cache, and release selection resources after clear/close. Run generic and LibraryPagingTests, format, then commit `Capture Library selection in bounded ephemeral storage`.

### Task 5: Library adoption, production-size validation and PR

**Files:** Create `LibraryBrowserModel.swift` and `LibraryBrowserColumns.swift`; modify `LibraryBrowserView.swift`, `LibraryDiagnosticRenderingTests.swift`, `LibraryPagingTests.swift`, README.md, docs/list-controls.md, and docs/testing.md.

**Interfaces:** `@MainActor LibraryBrowserModel: ObservableObject` owns `PagedResultsController<LibraryPagedSnapshot>` and `PagedSelectionController<LibrarySelectionStore>`. Initialize with the injected LibraryDatabase. Methods: `start() async`, `setQuery(_ query: LibraryBrowseQuery)`, `refresh()`, `stop()`, and `resolveFile(id: Int64) async throws -> FileRecord`. Store query/observation state and a pending refresh flag. Publish observation/action errors distinctly from page/selection errors. Columns are supplied by `LibraryBrowserColumns.make(showsFilenames: Bool, density: AppDensity) -> [PagedTableColumn<BrowserRow>]`.

- [ ] Adapt the existing Library rendering test to mount the new table with synthetic query/controller data; preserve all light/dark, density and unavailable/retired filename-height assertions. Add the production-size controller/table performance scenario to LibraryPagingTests before changing the live view. Measure initial placeholder render, last-row jump, async page latency, maximum main-actor heartbeat delay, decoded rows and peak cache. Traverse first/last/back; assert peak decoded cache <= declared bound and first-render decode <= that bound. Use XCTest attachments for metrics and screenshots, without machine-specific hard timing assertions.
- [ ] Run focused tests expecting the missing adapter, then implement model lifecycle with dependency injection. Query changes reset viewport; database refresh records the loaded anchor/focus IDs and uses `index(of:)` in the new snapshot. If deleted, clamp the old focused index without selecting its replacement. Refresh reconciles selection and republishes bounded visible membership; long-running old counts never overwrite a new query. End navigation cancels observer, requests and capture work, releases snapshot/cache, and closes selection storage.
- [ ] Implement native columns preserving title/artist/album/BPM/key/status/folder, path tooltips, muted text, optional filenames, density and accessibility. Use reusable cells; update existing status styling rather than reducing diagnostic states to an unlabeled icon. Move the existing sheets and drag-drop import unchanged onto the new host. Right-click actions capture stable ID, refetch at execution, then apply existing rename eligibility and history behavior. Finder also resolves the current path. A missing/deleted file surfaces an error instead of using a stale path.

```swift
let currentFile = try await model.resolveFile(id: clickedID)
try FileProcessingEligibility.requireProcessable(currentFile)
// Pass this freshly resolved record to the existing rename sheet flow.
```

- [ ] Wire ListSearchField, filter bar, sort callbacks, total/selected/outside-filter counts, Select All Matches, scoped deselection, Clear, busy state and visible Retry controls. Keep loading/empty/no-matches/page-error distinct. No disclosure UI. Remove `visibleRowCap`, SwiftUI table's materialized array, selection intersection with loaded rows, and the cap footer only after the production-size scenario passes and measured timing meets the spec targets. If timing misses, profile and fix before PR; document environmental limitations accurately, without skipping assertions.
- [ ] Update the README's Library usage paragraph while preserving its opening thesis. Replace Library's exception in docs/list-controls.md with continuous full-query browsing, captured full-query selection, hidden counts, and single-row action scope. Document the Test-host fixture command and metric meanings in docs/testing.md. Do not claim other preview screens were migrated.
- [ ] Run final checks serially for Xcode, with Rust commands allowed independently:

```sh
make test-swift
CARGO_TARGET_DIR=/Users/benny/dev/crate-agent/rust-core/target cargo test --manifest-path rust-core/Cargo.toml --workspace
CARGO_TARGET_DIR=/Users/benny/dev/crate-agent/rust-core/target cargo clippy --manifest-path rust-core/Cargo.toml --workspace -- -D warnings
cargo fmt --manifest-path rust-core/Cargo.toml --all --check
wc -c README.md
git diff --check
```

Run swiftformat on every changed Swift file before committing; use line ranges for small edits in legacy files to avoid unrelated formatting churn. Inspect generated screenshots using view_image. Existing environment skips must be reported; new tests must not be skipped. Baseline from PR #154: 693 Swift tests, 15 environment skips, zero failures; 82 Rust tests.
- [ ] Commit `Adopt paged Library browsing and full-query selection`. Use the requesting-code-review skill for one fresh whole-branch review against `24f347449d9884ac7da1b868792d4de740d513f2`, fix verified findings and rerun affected checks. Push `feat/paged-library`, open a PR closing #134 with the three review sections, measured metrics, tests and remaining limitations. Do not merge. Keep this worktree while the PR is open.

## Plan self-review

All approved-spec sections map to tasks: generic boundaries/cache/errors (1), native interaction and rendering (2), consistent snapshots/SQL/observation (3), captured membership/reconciliation/resource lifetime (4), Library controls/actions/navigation/performance/docs (5). All five Review Focus cases have owning tests above. Names and associated types are shared through PagedQuery.swift; range selection is defined in Task 1, routed by Task 2, and implemented for Library in Task 4. No new Library mutation or dependency is introduced. Owner review and execution-method choice precede implementation.
