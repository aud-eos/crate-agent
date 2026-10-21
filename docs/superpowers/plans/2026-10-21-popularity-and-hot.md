# Popularity and Hot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every Library track an all-time Popularity score and a Hot score from ListenBrainz and Deezer, looked up in the background only after the owner switches a source on, sortable in the Library and shown as "off" until then.

**Architecture:** A `popularity_lookups` history table and a derived `popularity_scores` table, keyed by the checklist's recording key, are written only by `PopularityStore`. `PopularityService` (the `SeratoPlayCountService` shape) refreshes stale recordings through two keyless clients built on `RetryingLookupRequester`, and seeds Hot from the Deezer chart. The Library joins `popularity_scores` in `checklist_facts` like `serato_play_counts`, adds two sort columns, and a sheet explains and enables sources the first time one is sorted while off.

**Tech Stack:** Swift 6, GRDB, URLSession through `URLLoading`, XCTest. ListenBrainz `POST /1/popularity/recording` and Deezer `GET /track/isrc:`, `/search`, `/chart/0/tracks`.

**Spec:** `docs/superpowers/specs/2026-10-17-library-readiness-design.md` ("Popularity signals", "My calls", "Left to the builder").

## Global Constraints

- Invariant 8: at 30,000 files, sort by Popularity or Hot, chip counts and facet options each finish under 500 ms; the background writer's longest hold stays under 500 ms.
- Only artist, title, ISRC and MusicBrainz recording IDs leave the machine. Each source is switched off until the owner enables it in the sheet or Settings.
- A missing score shows `LibraryChecklistMessages.unknown`, never 0, and sorts last in both directions. While every source is off the cell shows "off".
- Lookups never block browsing: they run off the main actor, rate-limited to one request per second per source, in batches of 50 recordings per transaction.
- Shared strings in `CrateAgent/Constants/PopularityMessages.swift`; no chevron disclosures; descriptive names.

## Review Focus

- A recording with no MusicBrainz ID and no ISRC: Deezer search by artist and title, lowest-confidence, so a search hit whose artist does not normalize-match the file's artist is discarded (Task 4 test `testSearchHitWithAnotherArtistIsIgnored`).
- Sources switched off after lookups ran: scores stay, cells show the stored score, and no request is sent (Task 4 test `testDisabledSourcesSendNothing`).
- Offline: status `.failed(offline message)`, previous scores untouched (Task 4 test `testOfflineKeepsPreviousScores`).
- Two lookups less than 7 days apart: Hot stays unknown rather than reporting noise (Task 1 test `testHotNeedsSevenDaysBetweenObservations`).
- A chart entry matching several local files (encodings of one recording): all share one Hot value through the recording key (Task 5 test `testChartSeedReachesEveryEncodingOfARecording`).

---

### Task 1: Schema, store and scoring

**Files:**
- Create: `CrateAgent/Database/Migrations/AddPopularityMigration.swift`
- Create: `CrateAgent/Services/Popularity/PopularityStore.swift`
- Create: `CrateAgent/Services/Popularity/PopularityScoring.swift`
- Modify: `CrateAgent/Database/Database.swift` (register after `AddCleanupKeeperIndexMigration`)
- Modify: `CrateAgent/Services/SeratoLibraryFacts.swift` (`ChecklistSource.popularity = "popularity"`, skipped in `storedStamps` like `.history`)
- Test: `CrateAgentTests/PopularityStoreTests.swift`

**Interfaces:**
- Produces:
  - Migration `034_add_popularity`:
    ```sql
    CREATE TABLE popularity_lookups (
        recording_key TEXT NOT NULL, source TEXT NOT NULL, observed_at INTEGER NOT NULL,
        value REAL NOT NULL, PRIMARY KEY (recording_key, source, observed_at)) WITHOUT ROWID;
    CREATE TABLE popularity_scores (
        recording_key TEXT PRIMARY KEY, all_time REAL, hot REAL, detail TEXT NOT NULL, updated_at INTEGER NOT NULL);
    ```
  - `enum PopularitySource: String, CaseIterable, Codable, Sendable { case listenBrainz = "listenbrainz", deezer = "deezer" }`
  - `struct PopularityObservation: Equatable, Sendable { let recordingKey: String; let source: PopularitySource; let observedAt: Int64; let value: Double }`
  - `enum PopularityStore`:
    - `static let lookupsTable = "popularity_lookups"`, `static let scoresTable = "popularity_scores"`
    - `static func record(_ observations: [PopularityObservation], now: Int64, in database: GRDB.Database) throws` inserts the lookups, then recomputes and upserts `popularity_scores` for each touched key from its full lookup history with `PopularityScoring`.
    - `static func staleRecordingKeys(limit: Int, olderThan: Int64, in database: GRDB.Database) throws -> [PopularityCandidate]` where `struct PopularityCandidate { let recordingKey: String; let recordingMBID: String?; let isrc: String?; let artist: String; let title: String }`, from active files joined through `files LEFT JOIN tracks`, keyed by `KeeperMarks.recordingKeySQL`, with no score or `updated_at < olderThan`, oldest first, one row per key.
    - `static func seedHot(_ seeds: [(recordingKey: String, hot: Double)], now: Int64, in database: GRDB.Database) throws` upserts `hot` and `updated_at` and leaves `all_time` and `detail` alone.
  - `enum PopularityScoring`:
    - `static let hotMinimumGap: Int64 = 7 * 86_400`, `static let hotWindow: Int64 = 28 * 86_400`, `static let refreshInterval: Int64 = 7 * 86_400`
    - `static func allTime(latest: [PopularitySource: Double]) -> Double?`: ListenBrainz listens map through `log10(value + 1) / 7 * 100` capped at 100; Deezer `rank` maps through `rank / 1_000_000 * 100` capped at 100; the result is the mean of the available sources, nil when none.
    - `static func hot(history: [PopularitySource: [(observedAt: Int64, value: Double)]], now: Int64) -> Double?`: per source, the latest value against the oldest value at least `hotMinimumGap` older and within `hotWindow`; growth `= (latest - earlier) / max(earlier, 1) * 100`; the mean across sources with a pair, nil otherwise.
    - `static func detail(latest: [PopularitySource: Double]) -> String` renders `PopularityMessages.detail(source:value:)` joined by " · ".

- [ ] **Step 1: Write the failing tests** in `PopularityStoreTests` with `LibraryDatabase.openInMemory()`:
  - `testRecordingLookupsDerivesAllTimeAndDetail`: record ListenBrainz 9_999 listens and Deezer rank 500_000 for key `k` at `now`; expect `all_time` = mean(log10(10_000)/7*100 = 57.14, 50) = 53.57 ± 0.01, `hot` nil, `detail` naming both sources.
  - `testHotNeedsSevenDaysBetweenObservations`: ListenBrainz 100 at day 0 and 150 at day 6: `hot` nil; add 200 at day 8: `hot` = (200-100)/100*100 = 100.
  - `testStaleKeysOrderOldestFirstAndSkipFresh`: three active files, one scored now, one scored 8 days ago, one unscored: `staleRecordingKeys(limit: 10, olderThan: now - refreshInterval)` returns the unscored then the 8-day one, with `recordingMBID` and `isrc` from `tracks`.
  - `testSeedHotKeepsAllTime`.
- [ ] **Step 2: Run** `xcodebuild ... -only-testing:CrateAgentTests/PopularityStoreTests`; expected FAIL on missing types.
- [ ] **Step 3: Implement** the migration, `ChecklistSource.popularity`, `PopularityStore` and `PopularityScoring`.
- [ ] **Step 4: Run** the same command; expected PASS.
- [ ] **Step 5: Commit** `feat: store popularity lookups and derive all-time and hot scores`.

### Task 2: Library columns and sort

**Files:**
- Modify: `CrateAgent/Services/LibraryPaging/LibraryChecklist.swift` (`filesCTEs`: `LEFT JOIN popularity_scores AS popularity ON popularity.recording_key = <KeeperMarks.recordingKeySQL>`; project `popularity.all_time AS popularity_all_time, popularity.hot AS popularity_hot, popularity.detail AS popularity_detail`; add `PopularityStore.scoresTable` to `observedTables`)
- Modify: `CrateAgent/Services/LibraryPaging/LibraryBrowseQuery.swift` (`LibraryBrowseSort.Column.popularity = "popularity"`, `.hot = "hot"`; `sql` returns `checklist.popularity_all_time` / `checklist.popularity_hot`; both `isChecklist`; `pageSQL` selects the three columns)
- Modify: `CrateAgent/Models/BrowserRow.swift` (`popularityAllTime: Double?`, `popularityHot: Double?`, `popularityDetail: String?`, `popularitySortKey`, `hotSortKey`, `init(row:)` reads)
- Modify: `CrateAgent/Constants/LibraryChecklistMessages.swift` (`popularityColumn = "Popularity"`, `hotColumn = "Hot"`, `popularityOff = "off"`)
- Modify: `CrateAgent/Views/LibraryBrowserColumns.swift` (two definitions after My plays, width 80; cell shows `Int(score.rounded())` monospaced, `showUnknown()` when nil and a source is enabled, `popularityOff` when none is; tooltip `popularityDetail`)
- Modify: `CrateAgentTests/Support/PagedLibraryFixture.swift` (`seedChecklist` inserts `popularity_scores` for `id % 2 = 0`), `CrateAgentTests/LibraryPagingTests.swift` (add `.popularity, .hot` to the sort loop)
- Test: `CrateAgentTests/LibraryChecklistTests.swift`

**Interfaces:**
- Consumes: `PopularityStore.scoresTable`, `PopularityScoring`.
- Produces: `BrowserRow.popularityAllTime`, `popularityHot`, `popularityDetail`; `LibraryBrowseSort.Column.popularity`, `.hot`. The cell needs `LibraryBrowserColumns.make(... popularityEnabled: @escaping () -> Bool)`; Task 6 passes the preference.

- [ ] **Step 1: Write the failing test** `testPopularitySortsKnownScoresFirstAndUnknownLast`: seed scores for two titled files (80 and 20), sort by `.popularity` ascending: ids are [20-file, 80-file, then the rest]; descending: [80-file, 20-file, then the rest]; `rows[...]?.popularityDetail` equals the stored detail.
- [ ] **Step 2: Run** `-only-testing:CrateAgentTests/LibraryChecklistTests`; expected FAIL on the missing column.
- [ ] **Step 3: Implement** the SQL, sort, row and column changes.
- [ ] **Step 4: Run** `LibraryChecklistTests` and `LibraryPagingTests/testChecklistSortFilterAndCountsStayWithinBudgetsAtThirtyThousandFiles`; expected PASS within 500 ms per query.
- [ ] **Step 5: Commit** `feat: sort the Library by Popularity and Hot`.

### Task 3: ListenBrainz and Deezer clients

**Files:**
- Create: `CrateAgent/Services/Popularity/ListenBrainzClient.swift`, `CrateAgent/Services/Popularity/DeezerClient.swift`
- Test: `CrateAgentTests/PopularityClientTests.swift` (uses `StubLoader` from `AcoustIDClientTests.swift`)

**Interfaces:**
- Produces:
  - `struct ListenBrainzClient(loader: any URLLoading, limiter: RateLimiter, appVersion: String)`; `func listenCounts(recordingMBIDs: [String]) async throws -> [String: Int]` POSTs JSON `{"recording_mbids": [...]}` to `https://api.listenbrainz.org/1/popularity/recording` with the crate-agent User-Agent and reads `[{recording_mbid, total_listen_count}]`, dropping null counts.
  - `struct DeezerTrack: Equatable, Sendable { let id: Int; let title: String; let artist: String; let rank: Int }`
  - `struct DeezerClient(loader:limiter:)`; `func track(isrc: String) async throws -> DeezerTrack?` (`GET https://api.deezer.com/track/isrc:<isrc>`; a body with `"error"` returns nil); `func search(artist: String, title: String) async throws -> DeezerTrack?` (`GET /search?q=artist:"<artist>" track:"<title>"&limit=1`, first of `data`); `func chart(limit: Int = 100) async throws -> [DeezerTrack]` (`GET /chart/0/tracks?limit=`).
  - Both use `RetryingLookupRequester` and throw `LookupError`.

- [ ] **Step 1: Write the failing tests**: `testListenCountsPostsIDsAndParsesCounts` (request URL, method, JSON body, User-Agent contains `crate-agent/test`; returns `["mbid-a": 123]` and drops the null entry); `testDeezerTrackByISRCReturnsNilOnErrorBody`; `testDeezerSearchQuotesArtistAndTitle` (query contains `artist:"Daft Punk"`); `testDeezerChartParsesRanks`.
- [ ] **Step 2: Run** `-only-testing:CrateAgentTests/PopularityClientTests`; expected FAIL.
- [ ] **Step 3: Implement** both clients.
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `feat: add ListenBrainz and Deezer popularity clients`.

### Task 4: PopularityService refresh

**Files:**
- Create: `CrateAgent/Services/Popularity/PopularityService.swift`
- Create: `CrateAgent/Constants/PopularityMessages.swift`
- Modify: `CrateAgent/App/UserPreferences.swift` (`PreferencesStore.isPopularitySourceEnabled(_:) -> Bool`, `setPopularitySource(_:enabled:)`, keys `"PopularitySource:<raw>"`; `popularityPromptShown: Bool`)
- Test: `CrateAgentTests/PopularityServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 store, Task 3 clients, `LibrarySyncReadiness.capture()`.
- Produces:
  - `@MainActor final class PopularityService: ObservableObject` with `enum Status: Equatable { case off, notRefreshed, refreshing(done: Int, total: Int), refreshed(count: Int), failed(String) }`, `@Published private(set) var status`, `init(database: LibraryDatabase, preferences: PreferencesStore, readiness: LibrarySyncReadiness?, listenBrainz: ListenBrainzClient, deezer: DeezerClient, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) })`, `func refresh() async` (coalesced like `SeratoPlayCountService.refresh`), `static let batchSize = 50`, `static let passLimit = 500`.
  - `refreshOnce()`: enabled sources from preferences; none → `.off`, return. Capture readiness (not ready → return quietly). Loop batches of `staleRecordingKeys(limit: batchSize, olderThan: now - refreshInterval)` up to `passLimit`: ListenBrainz for candidates with an MBID in one call; Deezer `track(isrc:)` when there is an ISRC, else `search` whose hit's artist must equal the candidate's artist under `GenreOption.normalized`-style folding (reuse `BlankText`/`folding(options: [.caseInsensitive, .diacriticInsensitive])`); `record(...)` in one write per batch after `authorization.check()`. A `LookupError` stops the pass with `.failed(error.localizedDescription)`; a completed pass writes `SeratoLibraryFacts.writeStamp(.popularity, "{}")` and sets `.refreshed(count:)`.
  - `PopularityMessages`: `title = "Popularity"`, `off = "Popularity is off"`, `sheetTitle`, `sheetBody = "Popularity looks each track up on the services you turn on. Only the artist, title, ISRC and MusicBrainz recording ID are sent."`, per-source name and what it receives, `enable = "Turn on"`, `notNow = "Not now"`, `detail(source:value:)`, status strings.

- [ ] **Step 1: Write the failing tests** with an in-memory database, `IsolatedPreferences`, `RateLimiter.noop` and sequenced stub loaders: `testRefreshLooksUpEnabledSourcesAndStoresScores` (two files, one with MBID+ISRC, one with neither; expect one ListenBrainz POST, one Deezer ISRC GET, one Deezer search GET, two score rows, stamp written, status `.refreshed(count: 2)`); `testDisabledSourcesSendNothing` (loader callCount 0, status `.off`); `testOfflineKeepsPreviousScores` (`OfflineLoader`; existing score row unchanged; status `.failed`); `testSearchHitWithAnotherArtistIsIgnored`.
- [ ] **Step 2: Run** `-only-testing:CrateAgentTests/PopularityServiceTests`; expected FAIL.
- [ ] **Step 3: Implement** the service, preferences and messages.
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `feat: refresh popularity from ListenBrainz and Deezer in the background`.

### Task 5: Seed Hot from the Deezer chart

**Files:**
- Modify: `CrateAgent/Services/Popularity/PopularityService.swift` (`seedHotFromChart()` run at the end of a successful pass when Deezer is enabled, at most once per `PopularityScoring.refreshInterval`, recorded in preferences `popularityChartSeededAt`)
- Modify: `CrateAgent/Services/Popularity/PopularityStore.swift` (`static func recordingKeys(matching entries: [(artist: String, title: String)], in database:) throws -> [Int: [String]]` by folded artist and title over active files' `files.artist/title`, index in the entries array to recording keys)
- Test: `CrateAgentTests/PopularityServiceTests.swift`

**Interfaces:**
- Produces: a chart position `p` (1-based) seeds `hot = 100 - p + 1` for each matching recording key through `PopularityStore.seedHot`.

- [ ] **Step 1: Write the failing test** `testChartSeedReachesEveryEncodingOfARecording`: two files sharing one `track_id`, chart body with that artist and title at position 3; after refresh both rows (same recording key) have `hot = 98` and the unmatched file has `hot` nil.
- [ ] **Step 2: Run**; expected FAIL.
- [ ] **Step 3: Implement**.
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `feat: seed Hot from the Deezer chart`.

### Task 6: Sheet, Settings, Workers card and wiring

**Files:**
- Create: `CrateAgent/Views/PopularitySourcesSheet.swift` (a toggle per source with its name and what it receives, `sheetBody`, buttons `enable` and `notNow`; writes preferences and calls `popularity.refresh()`)
- Modify: `CrateAgent/Views/SettingsView.swift` (a Popularity section with the same toggles)
- Modify: `CrateAgent/Views/LibraryPagedContent.swift` / `LibraryBrowserView.swift` (sorting by `.popularity` or `.hot` while no source is enabled and `popularityPromptShown == false` presents the sheet once; pass `popularityEnabled` to `LibraryBrowserColumns.make`)
- Modify: `CrateAgent/Views/WorkersView.swift` (`PopularityCard` showing `PopularityService.status`, with a "Refresh now" button)
- Modify: `CrateAgent/App/AppServices.swift` (construct `ListenBrainzClient`, `DeezerClient` with their own `RateLimiter(minInterval: 1.0)`, `PopularityService`; refresh on `.ready` beside play counts; a `Task` that refreshes every 6 hours while the app runs)
- Modify: `docs/library-checklist.md` (a "Popularity and Hot" section: sources, what is sent, scoring formulas, refresh cadence, chart seeding, off/unknown rules), `docs/workers.md` (the card)
- Test: none beyond Task 4 (views are wiring and copy)

- [ ] **Step 1: Implement** the views and wiring.
- [ ] **Step 2: Build** `xcodebuild ... build-for-testing`; expected success, and run `LibraryStartupPerformanceTests` once to confirm writer-hold budgets with the service constructed.
- [ ] **Step 3: Commit** `feat: enable popularity sources from a sheet and show their status`.
