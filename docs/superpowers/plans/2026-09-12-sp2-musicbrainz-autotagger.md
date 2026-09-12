# SP-2 MusicBrainz Auto-Tagger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify tracks by audio fingerprint and correct their metadata against MusicBrainz under per-track, per-field human review, writing clean tags to files and canonical identity (MBIDs/AcoustID/ISRC) to the database.

**Architecture:** Swift `URLSession` + `Codable` clients (AcoustID → MusicBrainz) drive lookups; the Rust core gains one new FFI function (`encode_fingerprint`) and a `year` field on the existing tag writer. Confirmed matches apply through one new `TrackMutation` case (`applyMusicBrainzMatch`) via `OperationEngine.applyBatch`, gaining undo + history for free. The `tracks` table gets its first writer here.

**Tech Stack:** Swift 5.9 / SwiftUI (macOS), GRDB.swift, Rust (uniffi FFI, `rusty_chromaprint`, `lofty`), XCTest, `cargo test`.

**Spec:** `docs/superpowers/specs/2026-09-12-sp2-musicbrainz-autotagger-design.md` — read it alongside this plan; the plan argues from it.

## Global Constraints

- **Invariant #1:** all state changes go through `OperationEngine.applyMutation`/`applyBatch`. SP-2 adds one mutation case; no parallel write path.
- **Invariant #2:** every mutation writes `payload_json` + `inverse_payload_json`; undo must round-trip.
- **Invariant #3:** never write Serato library files while Serato is running — route through `OperationEngine` (the watchdog queues Serato-DB writes; file-tag and app-DB writes proceed).
- **Invariant #4:** track identity is the Chromaprint fingerprint, stored on `tracks`; `files.path` is a label.
- **No silent failures:** every lookup/apply failure surfaces in the UI (per-row reason chip or panel banner); never `log + continue`.
- **Secrets:** the AcoustID API key lives in the macOS Keychain only — never in SQLite, the event log, or logs.
- **Comments:** none unless the *why* is non-obvious.
- **Formatter:** `cargo fmt` (Rust), `swiftformat` (Swift) before each commit. Note: `make format` reformats the whole tree — run the formatter on touched files and check `git diff --stat` before committing a focused change.
- **Latest-stable deps only; no pre-release.** No new Swift dependencies (URLSession/Codable/Security are stdlib). No `reqwest`/`tokio` in the uniffi core.
- **MusicBrainz etiquette:** ≤1 request/second, descriptive `User-Agent` `crate-agent/<version> ( <contact-url> )`.
- **Match existing test style** in `CrateAgentTests/` and the Rust crates. Test snippets below are XCTest-shaped; adapt to swift-testing if that is what the suite already uses.

---

## File Structure

**Rust (`rust-core/`):**
- Modify `src/crate-agent-core.udl` — declare `encode_fingerprint`; add `year` to `AudioTagUpdate`.
- Modify `src/ffi.rs` — implement `encode_fingerprint` (delegates to fingerprint-core).
- Modify `fingerprint-core/src/lib.rs` — `encode_fingerprint(raw: &[u32]) -> String`.
- Modify `src/tags.rs` — write `year` in `apply_update_to_tag`.

**Swift — Database (`CrateAgent/Database/`):**
- Create `Migrations/007_AddMusicBrainzColumns.swift` — additive `tracks` columns.
- Modify `Database.swift:94-100` — register the migration.

**Swift — Models (`CrateAgent/Models/`):**
- Modify `EventRecord.swift:65-77` — add `musicBrainzMatchApplied` `EventType` case.
- Create `MusicBrainzModels.swift` — `Codable` response types + the resolved `MatchCandidate`.

**Swift — Services (`CrateAgent/Services/`):**
- Create `FingerprintEncoder.swift` — bytes → `[UInt32]` → base64 (bridges FFI).
- Create `RateLimiter.swift` — serial ≥1s spacing + backoff.
- Create `LookupCache.swift` — disk cache keyed by fingerprint / recording MBID.
- Create `AcoustIDClient.swift`, `MusicBrainzClient.swift` — injectable URL loader.
- Create `ReleaseSelector.swift` — default-release heuristic.
- Create `TitleMatcher.swift` — the tiered title logic.
- Create `AcoustIDKeyStore.swift` — Keychain wrapper.
- Create `AutoTaggerService.swift` — orchestrates encode → AcoustID → MB → `MatchCandidate`.
- Modify `OperationEngine.swift` — `applyMusicBrainzMatch` case, payload, apply, inverse.

**Swift — Views (`CrateAgent/Views/`):**
- Modify `MainWindowView.swift:10-74` — `autoTag` section + detail wiring.
- Create `AutoTaggerView.swift` — review queue panel.
- Create `AutoTagReviewRow.swift` — per-row diff, per-field toggles, title control.
- Modify `SettingsView.swift` — Auto-Tag pane (API key field).

**Tests (`CrateAgentTests/`, Rust crates):**
- Rust `#[test]` in `fingerprint-core/src/lib.rs`, `src/tags.rs`.
- Swift: one test file per pure unit; mutation apply/undo in an OperationEngine test file; fixture JSON under `CrateAgentTests/Fixtures/`.

---

## Task 1: Migration — add MusicBrainz columns to `tracks`

**Files:**
- Create: `CrateAgent/Database/Migrations/007_AddMusicBrainzColumns.swift`
- Modify: `CrateAgent/Database/Database.swift:94-100` (migration registration)
- Test: `CrateAgentTests/MigrationTests.swift` (add a case; create the file if absent, matching existing migration-test style)

**Interfaces:**
- Consumes: existing GRDB `DatabaseMigrator` registration pattern in `Database.swift`.
- Produces: `tracks.musicbrainz_release_id TEXT`, `tracks.musicbrainz_artist_id TEXT`, `tracks.isrc TEXT`.

- [ ] **Step 1: Write the failing test** — after running all migrations, the three columns exist on `tracks`.

```swift
func testMigration007AddsMusicBrainzColumns() throws {
    let dbQueue = try DatabaseQueue()            // in-memory
    try AppDatabase.migrator.migrate(dbQueue)    // use the project's migrator accessor
    try dbQueue.read { db in
        let columns = try db.columns(in: "tracks").map(\.name)
        XCTAssertTrue(columns.contains("musicbrainz_release_id"))
        XCTAssertTrue(columns.contains("musicbrainz_artist_id"))
        XCTAssertTrue(columns.contains("isrc"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/MigrationTests/testMigration007AddsMusicBrainzColumns`
Expected: FAIL (columns absent).

- [ ] **Step 3: Create the migration** — follow the existing migration file shape (e.g. `AddSeratoMetadataToFilesMigration.swift`).

```swift
import GRDB

enum AddMusicBrainzColumnsMigration {
    static let identifier = "007_add_musicbrainz_columns"
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try db.alter(table: "tracks") { table in
                table.add(column: "musicbrainz_release_id", .text)
                table.add(column: "musicbrainz_artist_id", .text)
                table.add(column: "isrc", .text)
            }
        }
    }
}
```

- [ ] **Step 4: Register it** in `Database.swift` after `AddEventsBatchAggIndex` (keep registration order; migrations are append-only).

```swift
AddMusicBrainzColumnsMigration.register(&migrator)
```

- [ ] **Step 5: Run test to verify it passes** — same command as Step 2. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add CrateAgent/Database/Migrations/007_AddMusicBrainzColumns.swift CrateAgent/Database/Database.swift CrateAgentTests/MigrationTests.swift
git commit -m "feat(sp2): add musicbrainz_release_id/artist_id/isrc to tracks"
```

---

## Task 2: Rust — `encode_fingerprint` FFI

**Files:**
- Modify: `rust-core/fingerprint-core/src/lib.rs` (encoder + test)
- Modify: `rust-core/src/ffi.rs` (uniffi export)
- Modify: `rust-core/src/crate-agent-core.udl` (declaration)

**Interfaces:**
- Consumes: `rusty_chromaprint::{encode_fingerprint, Configuration}` (already a dependency), and the raw `Vec<u32>` produced by `fingerprint_file`.
- Produces: `encode_fingerprint(raw: sequence<u32>) -> string` (base64url, AcoustID-compatible).

- [ ] **Step 1: Write the failing test** in `fingerprint-core/src/lib.rs`. Fingerprint a checked-in fixture, encode, and compare against a golden string captured from `fpcalc` for the same file. (Generate the golden once with `fpcalc -raw` / `fpcalc` on the fixture and paste it; document the command in a comment.)

```rust
#[test]
fn encode_matches_fpcalc_golden() {
    let raw = fingerprint_file(std::path::Path::new(
        concat!(env!("CARGO_MANIFEST_DIR"), "/../../test-fixtures/audio/sample.mp3"))).unwrap();
    let encoded = encode_fingerprint(&raw);
    // Golden from: fpcalc -length 120 test-fixtures/audio/sample.mp3  (the "FINGERPRINT=" value)
    let golden = include_str!("../../../test-fixtures/audio/sample.fingerprint.txt").trim();
    assert_eq!(encoded, golden);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path rust-core/Cargo.toml -p fingerprint-core encode_matches_fpcalc_golden`
Expected: FAIL (function undefined).

- [ ] **Step 3: Implement the encoder** in `fingerprint-core/src/lib.rs`. Use the same `Configuration::preset_test1()` already used by `fingerprint_file`, since AcoustID's encoded form embeds the algorithm id.

```rust
use rusty_chromaprint::{encode_fingerprint, Configuration};

pub fn encode_fingerprint_to_base64(raw: &[u32]) -> String {
    // encode_fingerprint(fingerprint, algorithm, base64) -> String
    rusty_chromaprint::encode_fingerprint(raw, Configuration::preset_test1().id(), true)
}
```

(If the installed `rusty_chromaprint` version exposes a different `encode_fingerprint` signature, match it — the goal is the base64url string fpcalc emits. Confirm against the golden.)

- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: PASS. If it fails on mismatch, verify the `fpcalc` `-length 120` flag matches `FINGERPRINT_MAX_DURATION_SECONDS`.

- [ ] **Step 5: Add the uniffi export** in `src/ffi.rs`:

```rust
#[uniffi::export]
pub fn encode_fingerprint(raw: Vec<u32>) -> String {
    fingerprint_core::encode_fingerprint_to_base64(&raw)
}
```

And in `src/crate-agent-core.udl`, inside `namespace crate_agent_core`:

```
string encode_fingerprint(sequence<u32> raw);
```

- [ ] **Step 6: Build the FFI + regenerate bindings**

Run: `./scripts/build-rust.sh`
Expected: builds clean; the generated Swift binding now exposes `encodeFingerprint(raw:)`.

- [ ] **Step 7: Commit**

```bash
cargo fmt --manifest-path rust-core/Cargo.toml
git add rust-core/ test-fixtures/audio/sample.fingerprint.txt
git commit -m "feat(sp2): expose encode_fingerprint FFI (AcoustID-compatible base64)"
```

---

## Task 3: Rust — write `year` in the tag writer

**Files:**
- Modify: `rust-core/src/tags.rs` (`AudioTagUpdate` struct + `apply_update_to_tag` + test)
- Modify: `rust-core/src/crate-agent-core.udl` (`AudioTagUpdate` dict)

**Interfaces:**
- Consumes: `lofty` `Accessor`/`ItemKey`, existing `AudioTagUpdate`.
- Produces: `AudioTagUpdate.year: Option<u32>` written to ID3v2.4 `TDRC` / Vorbis `DATE` / iTunes `©day`, round-trippable via `read_tags`.

- [ ] **Step 1: Write the failing test** in `src/tags.rs`.

```rust
#[test]
fn writes_and_reads_year() {
    let path = copy_fixture_to_temp("sample.mp3"); // existing test helper pattern
    let update = AudioTagUpdate { year: Some(1994), ..AudioTagUpdate::default() };
    write_tags(&path, &update).unwrap();
    assert_eq!(read_tags(&path).unwrap().year, Some(1994));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path rust-core/Cargo.toml writes_and_reads_year`
Expected: FAIL (no `year` field on `AudioTagUpdate`).

- [ ] **Step 3: Add the field + write logic.** In `src/tags.rs` add `pub year: Option<u32>` to `AudioTagUpdate` (and its `Default`). In `apply_update_to_tag`:

```rust
if let Some(year) = update.year {
    tag.set_year(year);   // lofty Accessor maps to TDRC / DATE / ©day
}
```

- [ ] **Step 4: Update the UDL** — add to the `AudioTagUpdate` dictionary in `src/crate-agent-core.udl`:

```
u32? year;
```

- [ ] **Step 5: Run test to verify it passes** — same command as Step 2. Expected: PASS.

- [ ] **Step 6: Rebuild bindings + commit**

```bash
./scripts/build-rust.sh
cargo fmt --manifest-path rust-core/Cargo.toml
git add rust-core/
git commit -m "feat(sp2): AudioTagUpdate can write year (TDRC/DATE/day)"
```

---

## Task 4: Swift — `FingerprintEncoder`

**Files:**
- Create: `CrateAgent/Services/FingerprintEncoder.swift`
- Test: `CrateAgentTests/FingerprintEncoderTests.swift`

**Interfaces:**
- Consumes: `deserializeHashesFromBytes(_:) -> [UInt32]` (exists in `FingerprintWorker.swift:538` — extract to a shared location if it is currently private; see note) and the FFI `encodeFingerprint(raw:)`.
- Produces: `FingerprintEncoder.base64(fromStoredBytes: Data) -> String?` (nil if bytes are empty/corrupt).

Note: if `deserializeHashesFromBytes` is `private` to `FingerprintWorker`, move it (and its `serialize` twin) into `FingerprintEncoder` as `static` functions and have `FingerprintWorker` call them — "share the mechanic, not the shape".

- [ ] **Step 1: Write the failing test**

```swift
func testRoundTripEncodesNonEmpty() {
    let hashes: [UInt32] = [0x0001, 0x00FF, 0xDEADBEEF]
    let bytes = FingerprintEncoder.serialize(hashes)
    XCTAssertEqual(FingerprintEncoder.deserialize(bytes), hashes)
    XCTAssertFalse(FingerprintEncoder.base64(fromStoredBytes: bytes)?.isEmpty ?? true)
}

func testEmptyBytesReturnNil() {
    XCTAssertNil(FingerprintEncoder.base64(fromStoredBytes: Data()))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/FingerprintEncoderTests`
Expected: FAIL (type missing).

- [ ] **Step 3: Implement**

```swift
enum FingerprintEncoder {
    static func serialize(_ hashes: [UInt32]) -> Data {
        var data = Data(capacity: hashes.count * 4)
        for hash in hashes { withUnsafeBytes(of: hash.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
    static func deserialize(_ bytes: Data) -> [UInt32] {
        stride(from: 0, to: bytes.count - (bytes.count % 4), by: 4).map {
            bytes[$0..<$0+4].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
    }
    static func base64(fromStoredBytes bytes: Data) -> String? {
        let hashes = deserialize(bytes)
        guard !hashes.isEmpty else { return nil }
        return encodeFingerprint(raw: hashes)   // FFI
    }
}
```

- [ ] **Step 4: Run test to verify it passes** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Repoint `FingerprintWorker`** to `FingerprintEncoder.serialize/deserialize` if you moved them; run its existing tests to confirm no regression.

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/FingerprintWorkerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add CrateAgent/Services/FingerprintEncoder.swift CrateAgentTests/FingerprintEncoderTests.swift CrateAgent/Services/FingerprintWorker.swift
git commit -m "feat(sp2): FingerprintEncoder bridges stored bytes to AcoustID base64"
```

---

## Task 5: Swift — response models + `MatchCandidate`

**Files:**
- Create: `CrateAgent/Models/MusicBrainzModels.swift`
- Create: `CrateAgentTests/Fixtures/acoustid_multi.json`, `acoustid_empty.json`, `mb_recording.json`, `mb_recording_no_isrc.json` (real captured responses)
- Test: `CrateAgentTests/MusicBrainzModelsTests.swift`

**Interfaces:**
- Produces:
  - `AcoustIDResponse` / `AcoustIDResult { score: Double; recordingIDs: [String] }`
  - `MBRecording { title; artistCredit: [MBArtistCredit]; releases: [MBRelease]; releaseGroup: MBReleaseGroup?; isrcs: [String] }`
  - `MBRelease { id; title; date: String?; country: String?; status: String? }`
  - `MBReleaseGroup { id; firstReleaseDate: String? }`  (year source)
  - `MatchCandidate` — the resolved, UI-ready match (defined here, consumed by Tasks 9–14):

```swift
struct MatchCandidate: Equatable {
    let fileID: Int64
    let score: Double                 // 0...1 AcoustID
    let acoustID: String?
    let recordingMBID: String
    let artistMBID: String?
    var chosenRelease: MBRelease      // mutable via "pick a different release"
    let availableReleases: [MBRelease]
    let releaseMBID: String
    let isrc: String?
    // proposed values:
    let proposedArtist: String
    let proposedTitle: String
    var proposedAlbum: String         // follows chosenRelease
    let proposedYear: Int?            // release-group first-release-date year (fixed)
}
```

- [ ] **Step 1: Write the failing tests** — parse each fixture; assert multi-release, missing-ISRC, and empty cases.

```swift
func testParsesMultiReleaseRecording() throws {
    let data = fixture("mb_recording.json")
    let rec = try JSONDecoder().decode(MBRecording.self, from: data)
    XCTAssertGreaterThan(rec.releases.count, 1)
    XCTAssertNotNil(rec.releaseGroup?.firstReleaseDate)
    XCTAssertFalse(rec.isrcs.isEmpty)
}
func testRecordingWithNoISRC() throws {
    let rec = try JSONDecoder().decode(MBRecording.self, from: fixture("mb_recording_no_isrc.json"))
    XCTAssertTrue(rec.isrcs.isEmpty)
}
func testEmptyAcoustIDResults() throws {
    let resp = try JSONDecoder().decode(AcoustIDResponse.self, from: fixture("acoustid_empty.json"))
    XCTAssertTrue(resp.results.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/MusicBrainzModelsTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Capture fixtures** — with a real AcoustID key and a known track, save the raw JSON of an AcoustID lookup and a `GET /ws/2/recording/<mbid>?inc=releases+release-groups+artist-credits+isrcs&fmt=json` into the fixture files. Trim to a couple of releases for size. Pick a recording with no ISRC for the `no_isrc` fixture.

- [ ] **Step 4: Implement the `Codable` types** in `MusicBrainzModels.swift` with `CodingKeys` mapping MB's kebab keys (`artist-credit`, `release-group`, `first-release-date`). Keep decoding lenient (all release detail fields optional) so a sparse response never throws.

- [ ] **Step 5: Run tests to verify they pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add CrateAgent/Models/MusicBrainzModels.swift CrateAgentTests/MusicBrainzModelsTests.swift CrateAgentTests/Fixtures/
git commit -m "feat(sp2): AcoustID + MusicBrainz Codable models and MatchCandidate"
```

---

## Task 6: Swift — `RateLimiter` + `LookupCache`

**Files:**
- Create: `CrateAgent/Services/RateLimiter.swift`, `CrateAgent/Services/LookupCache.swift`
- Test: `CrateAgentTests/RateLimiterTests.swift`, `CrateAgentTests/LookupCacheTests.swift`

**Interfaces:**
- Produces:
  - `actor RateLimiter { init(minInterval: TimeInterval, clock:) ; func acquire() async }`
  - `LookupCache { func data(forKey:) -> Data? ; func store(_ data: Data, forKey:) }` (disk-backed under Application Support; key = SHA-256 of the logical key string)

- [ ] **Step 1: Write the failing tests**

```swift
func testEnforcesMinimumSpacing() async {
    let clock = TestClock()
    let limiter = RateLimiter(minInterval: 1.0, clock: clock)
    await limiter.acquire()                 // immediate
    async let second: Void = limiter.acquire()
    await clock.advance(by: 0.9); ...       // still waiting
    await clock.advance(by: 0.2); await second   // released after ≥1s
    XCTAssertGreaterThanOrEqual(clock.now, 1.0)
}

func testCacheRoundTrips() {
    let cache = LookupCache(directory: tempDir())
    cache.store(Data("x".utf8), forKey: "fp:abc")
    XCTAssertEqual(cache.data(forKey: "fp:abc"), Data("x".utf8))
    XCTAssertNil(cache.data(forKey: "fp:missing"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/RateLimiterTests -only-testing:CrateAgentTests/LookupCacheTests`
Expected: FAIL.

- [ ] **Step 3: Implement** `RateLimiter` as an `actor` serializing `acquire()` with an injectable clock (so tests don't sleep); implement `LookupCache` writing files named by hashed key, reading back with `try?` (missing/unreadable → nil, no throw).

- [ ] **Step 4: Run tests to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CrateAgent/Services/RateLimiter.swift CrateAgent/Services/LookupCache.swift CrateAgentTests/RateLimiterTests.swift CrateAgentTests/LookupCacheTests.swift
git commit -m "feat(sp2): serial rate limiter + disk lookup cache"
```

---

## Task 7: Swift — `AcoustIDClient`

**Files:**
- Create: `CrateAgent/Services/AcoustIDClient.swift`
- Test: `CrateAgentTests/AcoustIDClientTests.swift`

**Interfaces:**
- Consumes: `RateLimiter`, `LookupCache`, `AcoustIDResponse` (Task 5), an injectable `URLLoading` protocol (`func data(for: URLRequest) async throws -> (Data, URLResponse)` — `URLSession` conforms; tests inject a stub).
- Produces: `AcoustIDClient.lookup(fingerprintBase64: String, durationSeconds: Int, apiKey: String) async throws -> [AcoustIDResult]` (sorted by score desc). Throws `LookupError.unauthorized` on 401, `.rateLimited` on 429, `.server` on 5xx, `.transport` otherwise.

- [ ] **Step 1: Write the failing tests** — stub loader returns `acoustid_multi.json` → results sorted; a 401 response → `.unauthorized`; a cache hit → no second loader call.

```swift
func testReturnsSortedResults() async throws {
    let loader = StubLoader(status: 200, body: fixture("acoustid_multi.json"))
    let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())
    let results = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")
    XCTAssertEqual(results, results.sorted { $0.score > $1.score })
}
func testUnauthorizedMapsToError() async {
    let client = AcoustIDClient(loader: StubLoader(status: 401, body: Data()), limiter: .noop, cache: .memory())
    await XCTAssertThrowsError(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "bad")) {
        XCTAssertEqual($0 as? LookupError, .unauthorized)
    }
}
func testCacheHitSkipsNetwork() async throws {
    let loader = CountingStubLoader(status: 200, body: fixture("acoustid_multi.json"))
    let cache = LookupCache.memory()
    let client = AcoustIDClient(loader: loader, limiter: .noop, cache: cache)
    _ = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")
    _ = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")
    XCTAssertEqual(loader.callCount, 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/AcoustIDClientTests`
Expected: FAIL.

- [ ] **Step 3: Implement** — build the `POST` to `https://api.acoustid.org/v2/lookup` (form body `client`, `duration`, `fingerprint`, `meta=recordings+recordingids`); cache key `acoustid:<sha256(fingerprint)>`; `await limiter.acquire()` before each network call; map status codes to `LookupError`; decode + sort.

- [ ] **Step 4: Run tests to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CrateAgent/Services/AcoustIDClient.swift CrateAgentTests/AcoustIDClientTests.swift
git commit -m "feat(sp2): AcoustIDClient with cache + rate limit + typed errors"
```

---

## Task 8: Swift — `MusicBrainzClient`

**Files:**
- Create: `CrateAgent/Services/MusicBrainzClient.swift`
- Test: `CrateAgentTests/MusicBrainzClientTests.swift`

**Interfaces:**
- Consumes: `RateLimiter`, `LookupCache`, `MBRecording` (Task 5), `URLLoading`, app version accessor.
- Produces: `MusicBrainzClient.recording(mbid: String) async throws -> MBRecording`. Sends `User-Agent: crate-agent/<version> ( <contact-url> )`; cache key `mb:<mbid>`; same `LookupError` mapping + backoff as Task 7.

- [ ] **Step 1: Write the failing tests** — stub returns `mb_recording.json` → decoded recording with releases + release-group; assert the request carried a non-empty `User-Agent`; cache hit skips network.

```swift
func testFetchesRecordingAndSetsUserAgent() async throws {
    let loader = HeaderCapturingLoader(status: 200, body: fixture("mb_recording.json"))
    let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory(), appVersion: "1.2.3")
    let rec = try await client.recording(mbid: "abc")
    XCTAssertFalse(rec.releases.isEmpty)
    XCTAssertTrue(loader.lastRequest?.value(forHTTPHeaderField: "User-Agent")?.contains("crate-agent/1.2.3") ?? false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/MusicBrainzClientTests`
Expected: FAIL.

- [ ] **Step 3: Implement** — `GET https://musicbrainz.org/ws/2/recording/<mbid>?inc=releases+release-groups+artist-credits+isrcs&fmt=json`, User-Agent header, cache, limiter, error mapping.

- [ ] **Step 4: Run test to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CrateAgent/Services/MusicBrainzClient.swift CrateAgentTests/MusicBrainzClientTests.swift
git commit -m "feat(sp2): MusicBrainzClient with polite User-Agent + cache"
```

---

## Task 9: Swift — `ReleaseSelector`

**Files:**
- Create: `CrateAgent/Services/ReleaseSelector.swift`
- Test: `CrateAgentTests/ReleaseSelectorTests.swift`

**Interfaces:**
- Produces: `ReleaseSelector.defaultRelease(from releases: [MBRelease], existingAlbum: String?) -> MBRelease?` — prefer a release whose title case-insensitively equals `existingAlbum`; else the earliest by `date` with `status == "Official"`; else the earliest by `date`; else the first. Nil only when `releases` is empty.

- [ ] **Step 1: Write the failing tests**

```swift
func testPrefersExistingAlbumMatch() {
    let picked = ReleaseSelector.defaultRelease(from: releases, existingAlbum: "Illmatic")
    XCTAssertEqual(picked?.title, "Illmatic")
}
func testFallsBackToEarliestOfficial() {
    let picked = ReleaseSelector.defaultRelease(from: releases, existingAlbum: nil)
    XCTAssertEqual(picked?.date, "1994-04-19")
}
func testEmptyReturnsNil() {
    XCTAssertNil(ReleaseSelector.defaultRelease(from: [], existingAlbum: "x"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/ReleaseSelectorTests`
Expected: FAIL.

- [ ] **Step 3: Implement** the heuristic as a pure static function (guard empty → nil; date parsing tolerant of `YYYY` / `YYYY-MM` / `YYYY-MM-DD`).

- [ ] **Step 4: Run tests to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CrateAgent/Services/ReleaseSelector.swift CrateAgentTests/ReleaseSelectorTests.swift
git commit -m "feat(sp2): default-release selection heuristic"
```

---

## Task 10: Swift — `TitleMatcher` (the tiered title logic)

**Files:**
- Create: `CrateAgent/Services/TitleMatcher.swift`
- Test: `CrateAgentTests/TitleMatcherTests.swift`

**Interfaces:**
- Produces:

```swift
enum TitleTier: Equatable {
    case exact                          // default: take MB
    case baseMatch(merged: String)      // default: merged (MB base + remainder)
    case annotationNoBase               // default: keep current
    case plain                          // default: take MB
}
enum TitleChoice { case keep, merge, take }
struct TitleDecision: Equatable { let tier: TitleTier; let defaultChoice: TitleChoice }

enum TitleMatcher {
    static func decide(current: String, proposed: String) -> TitleDecision
    static func value(for choice: TitleChoice, current: String, proposed: String, tier: TitleTier) -> String
    // helpers (also unit-tested):
    static func annotationSegments(in title: String) -> [String]   // (), [], trailing "- …"
    static func hasDroppedAnnotation(current: String, proposed: String) -> Bool
}
```

Detection rules (from the spec, grounded in the library scan):
- Normalize = lowercased, whitespace-collapsed, trimmed.
- **exact**: normalize(current) == normalize(proposed) → default `take`.
- **baseMatch**: normalize(proposed) is a prefix of normalize(current) with a non-empty remainder → default `merge`; `merged` = locate proposed in current case-insensitively, append everything after it (original formatting preserved).
- **annotationNoBase**: not exact/baseMatch, and `hasDroppedAnnotation` is true (current has a `()`/`[]`/trailing-`- ` segment, or a bare token from the confirmed DJ vocabulary, absent from proposed) → default `keep`.
- **plain**: none of the above → default `take`.
- DJ vocabulary constant (bare-token fallback only): `clean, dirty, explicit, radio edit, radio version, intro, outro, acapella, instrumental, extended, extended mix, club mix, original mix, main, edit, flip, bootleg, redrum, transition, remix, dub, short edit, quick hit, album version` (case-insensitive, whole-word).

- [ ] **Step 1: Write the failing tests** — one per tier plus the nuance cases the scan surfaced.

```swift
func testExact() {
    XCTAssertEqual(TitleMatcher.decide(current: "foo song title", proposed: "Foo Song Title").defaultChoice, .take)
}
func testBaseMatchMergesPreservingRemainder() {
    let d = TitleMatcher.decide(current: "foo song title [DJ foobar remix - radio version]", proposed: "Foo Song Title")
    XCTAssertEqual(d.tier, .baseMatch(merged: "Foo Song Title [DJ foobar remix - radio version]"))
    XCTAssertEqual(d.defaultChoice, .merge)
}
func testParenDirtyKeptWhenMBAlsoChangesBase() {
    let d = TitleMatcher.decide(current: "Foo Sng (Dirty)", proposed: "Foo Song")   // base differs (typo fix)
    XCTAssertEqual(d.tier, .annotationNoBase)
    XCTAssertEqual(d.defaultChoice, .keep)
}
func testCuratorCreditKept() {
    let d = TitleMatcher.decide(current: "Foo Song (MM Edit)", proposed: "Foo Song")
    XCTAssertEqual(d.defaultChoice, .merge)     // base matches → merge keeps "(MM Edit)"
}
func testBracketAndDashRemaindersMerge() {
    XCTAssertEqual(TitleMatcher.value(for: .merge, current: "foo [clean]", proposed: "Foo", tier: TitleMatcher.decide(current: "foo [clean]", proposed: "Foo").tier), "Foo [clean]")
    XCTAssertEqual(TitleMatcher.value(for: .merge, current: "foo - radio edit", proposed: "Foo", tier: TitleMatcher.decide(current: "foo - radio edit", proposed: "Foo").tier), "Foo - radio edit")
}
func testBareVocabWithoutDelimiterFallsToAnnotationOrMerge() {
    // "foo song radio edit" with proposed "Foo Song" → baseMatch (prefix) → merge keeps " radio edit"
    XCTAssertEqual(TitleMatcher.decide(current: "foo song radio edit", proposed: "Foo Song").defaultChoice, .merge)
}
func testPlainCorrection() {
    XCTAssertEqual(TitleMatcher.decide(current: "Foo Sog", proposed: "Foo Song").defaultChoice, .take)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/TitleMatcherTests`
Expected: FAIL.

- [ ] **Step 3: Implement** `TitleMatcher` per the rules. Keep `merged` construction index-safe: use `range(of: proposed, options: .caseInsensitive)` on the original `current`; if found at the start, `merged = proposed + current[range.upperBound...]`.

- [ ] **Step 4: Run tests to verify they pass** — same command. Expected: PASS. Add any scan-derived case that fails and fix.

- [ ] **Step 5: Commit**

```bash
git add CrateAgent/Services/TitleMatcher.swift CrateAgentTests/TitleMatcherTests.swift
git commit -m "feat(sp2): tiered title matcher (exact/base-merge/annotation/plain)"
```

---

## Task 11: Swift — `AcoustIDKeyStore` (Keychain)

**Files:**
- Create: `CrateAgent/Services/AcoustIDKeyStore.swift`
- Test: `CrateAgentTests/AcoustIDKeyStoreTests.swift`

**Interfaces:**
- Produces: `AcoustIDKeyStore { func save(_ key: String) throws ; func load() -> String? ; func delete() throws }` using `Security` framework generic-password items (service `com.crateagent.acoustid`). Never logs the value.

- [ ] **Step 1: Write the failing test** — save → load round-trips; delete → load nil. Use a unique service string per test run to avoid polluting the real keychain.

```swift
func testSaveLoadDelete() throws {
    let store = AcoustIDKeyStore(service: "com.crateagent.acoustid.test.\(UUID())")
    try store.save("secret-key")
    XCTAssertEqual(store.load(), "secret-key")
    try store.delete()
    XCTAssertNil(store.load())
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/AcoustIDKeyStoreTests`
Expected: FAIL.

- [ ] **Step 3: Implement** with `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete`; `save` upserts (delete-then-add). Return nil on `errSecItemNotFound`; throw on other OSStatus.

- [ ] **Step 4: Run test to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CrateAgent/Services/AcoustIDKeyStore.swift CrateAgentTests/AcoustIDKeyStoreTests.swift
git commit -m "feat(sp2): Keychain-backed AcoustID API key store"
```

---

## Task 12: Swift — `applyMusicBrainzMatch` mutation (apply + inverse)

**Files:**
- Modify: `CrateAgent/Services/OperationEngine.swift` (enum case ~1436; payload struct; `executeAndLog` switch ~849; new `applyMusicBrainzMatch` + inverse decode ~303)
- Modify: `CrateAgent/Models/EventRecord.swift:65-77` (add `musicBrainzMatchApplied`)
- Test: `CrateAgentTests/MusicBrainzMutationTests.swift`

**Interfaces:**
- Consumes: existing `applySeratoWrite`/`applyFileTagWrite` mechanics, `insertEvent`, `applyBatch`.
- Produces:

```swift
struct ApplyMusicBrainzMatchPayload: Codable, Sendable, Equatable {
    let fileID: Int64
    // identity (always applied):
    let acoustID: String?
    let recordingMBID: String
    let releaseMBID: String?
    let artistMBID: String?
    let isrc: String?
    let fingerprintHash: Data          // SHA-256 of the file's stored fingerprint
    // cherry-picked display fields (absent = not applied):
    let artist: String?
    let title: String?
    let album: String?
    let year: Int?
    // previous-state snapshots (filled by engine at apply time):
    var previousTrackID: Int64?
    var previousMetadata: SeratoMetadata?
    var previousFileTags: SeratoMetadata?
    var previousTrackIdentifiers: TrackIdentifiers?   // nil if track row created
    var createdTrackRow: Bool
}
```

Add `case applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload)` to `TrackMutation`, and `case musicBrainzMatchApplied = "music_brainz_match_applied"` to `EventType`.

- [ ] **Step 1: Write the failing tests** — the correctness core.

```swift
func testApplyCreatesTrackLinksFileWritesTagsAndEvent() async throws {
    let (engine, db, fileID) = try makeEngineWithFile(artist: "old", title: "old", album: "old")
    let payload = ApplyMusicBrainzMatchPayload(fileID: fileID, acoustID: "aid",
        recordingMBID: "rec", releaseMBID: "rel", artistMBID: "art", isrc: "ISRC123",
        fingerprintHash: sha256(sampleFingerprintBytes),
        artist: "Nas", title: "N.Y. State of Mind", album: "Illmatic", year: 1994,
        previousTrackID: nil, previousMetadata: nil, previousFileTags: nil,
        previousTrackIdentifiers: nil, createdTrackRow: false)
    _ = try await engine.apply(.applyMusicBrainzMatch(payload))
    try db.read { db in
        let file = try FileRecord.fetchOne(db, id: fileID)!
        XCTAssertNotNil(file.trackID)
        let track = try TrackRecord.fetchOne(db, id: file.trackID!)!
        XCTAssertEqual(track.musicbrainzRecordingID, "rec")
        XCTAssertEqual(track.isrc, "ISRC123")
        XCTAssertEqual(track.year, 1994)
        XCTAssertEqual(file.title, "N.Y. State of Mind")
        let event = try EventRecord.filter(Column("event_type") == "music_brainz_match_applied").fetchOne(db)
        XCTAssertNotNil(event?.inversePayloadJson)
    }
}

func testUndoRoundTripsNewTrackRow() async throws {
    let (engine, db, fileID) = try makeEngineWithFile(artist: "old", title: "old (Dirty)", album: "old")
    let batchID = try await engine.apply(.applyMusicBrainzMatch(/* full field set */))
    try await engine.undoBatch(batchID)
    try db.read { db in
        let file = try FileRecord.fetchOne(db, id: fileID)!
        XCTAssertEqual(file.title, "old (Dirty)")   // exact restore
        XCTAssertEqual(file.artist, "old")
        XCTAssertNil(file.trackID)                  // link removed
    }
}

func testUndoRoundTripsPreexistingTrackRow() async throws { /* seed a track row, apply, undo → identifiers restored, row kept */ }

func testPartialFieldSetOnlyWritesChosenFields() async throws {
    // title absent → file.title unchanged; album present → file.album updated
}

func testSeratoRunningQueuesSeratoWriteButProceedsWithTagAndDB() async throws {
    // watchdog stub returns isSeratoRunning = true → pendingSeratoWrites grows; files.title still updated; file-tag write still dispatched
}

func testBatchOfConfirmsIsOneUndoUnit() async throws {
    let ids = try await engine.applyBatch([.applyMusicBrainzMatch(a), .applyMusicBrainzMatch(b)], batchId: batch)
    // one batchId; undoBatch(batch) reverts both
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/MusicBrainzMutationTests`
Expected: FAIL (case/type missing).

- [ ] **Step 3: Implement the apply** inside `executeAndLog`'s switch. Fill the `previous…` snapshots from the current row before mutating. Steps: upsert `tracks` by `fingerprintHash` (set `createdTrackRow` accordingly), set `files.track_id`, update `files` metadata for applied artist/title/album, build the forward + inverse payloads, `insertEvent`, and return an `ExecutionResult` whose `seratoWrite` is a `.metadataUpdate` for applied artist/title/album plus a file-tag write (applied artist/title/album/year). Reuse `applySeratoWrite`/`applyFileTagWrite`; extract a shared helper if the tag/serato write construction would otherwise be copied.

- [ ] **Step 4: Implement the inverse** in `decodeInverseMutation` for `.musicBrainzMatchApplied`: restore `files.track_id`, `files` metadata, file tags from the snapshots; restore `tracks` identifiers if `createdTrackRow == false`, else null the identifiers set (leave the row).

- [ ] **Step 5: Run tests to verify they pass** — same command. Expected: PASS. Fix until green.

- [ ] **Step 6: Commit**

```bash
swiftformat CrateAgent/Services/OperationEngine.swift CrateAgent/Models/EventRecord.swift
git add CrateAgent/Services/OperationEngine.swift CrateAgent/Models/EventRecord.swift CrateAgentTests/MusicBrainzMutationTests.swift
git commit -m "feat(sp2): applyMusicBrainzMatch mutation with full inverse"
```

---

## Task 13: Swift — `AutoTaggerService` (orchestration)

**Files:**
- Create: `CrateAgent/Services/AutoTaggerService.swift`
- Modify: `CrateAgent/App/AppServices.swift` (expose the service)
- Test: `CrateAgentTests/AutoTaggerServiceTests.swift`

**Interfaces:**
- Consumes: `FingerprintEncoder`, `AcoustIDClient`, `MusicBrainzClient`, `ReleaseSelector`, `TitleMatcher`, `AcoustIDKeyStore`, `read_audio_tags` (duration), `FingerprintWorker` (to fingerprint on demand), the DB.
- Produces:

```swift
@MainActor final class AutoTaggerService: ObservableObject {
    enum RowState: Equatable { case pending, strong(MatchCandidate), weak(MatchCandidate), noMatch, failed(String) }
    @Published private(set) var rows: [Int64: RowState] = [:]
    func run(fileIDs: [Int64]) async            // populates rows progressively; cancellable
    func cancel()
    func candidate(for fileID: Int64) -> MatchCandidate?
}
```

For each file: ensure fingerprint (via worker if missing) → `FingerprintEncoder.base64` → `read_audio_tags().duration` → `AcoustIDClient.lookup` (top result) → `MusicBrainzClient.recording` → build `MatchCandidate` (chosen release via `ReleaseSelector`, year from release-group). Classify: `strong` ≥ 0.9, `weak` in 0.5..<0.9, `noMatch` if no result. Any thrown `LookupError` → `.failed(reason)` for that row; a `.unauthorized`/persistent `.server` sets a service-level `fatalError` banner and stops the pass.

- [ ] **Step 1: Write the failing tests** — inject stub clients; assert progressive classification and that a per-row failure doesn't abort the others; a 401 sets the fatal banner.

```swift
func testClassifiesStrongAndWeakAndNoMatch() async { /* stub scores 0.98, 0.7, none */ }
func testPerRowFailureIsolated() async { /* one file throws .transport → .failed; others still resolve */ }
func testUnauthorizedStopsPassWithBanner() async { /* client throws .unauthorized → service.fatalBanner != nil */ }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/AutoTaggerServiceTests`
Expected: FAIL.

- [ ] **Step 3: Implement** the orchestration with a `Task` you retain for `cancel()`; check `Task.isCancelled` between files; publish `rows` on the main actor as each resolves.

- [ ] **Step 4: Run tests to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CrateAgent/Services/AutoTaggerService.swift CrateAgent/App/AppServices.swift CrateAgentTests/AutoTaggerServiceTests.swift
git commit -m "feat(sp2): AutoTaggerService orchestrates lookup → candidates"
```

---

## Task 14: Swift — Review UI + Settings pane

**Files:**
- Modify: `CrateAgent/Views/MainWindowView.swift:10-74` (add `autoTag` section + detail)
- Create: `CrateAgent/Views/AutoTaggerView.swift`, `CrateAgent/Views/AutoTagReviewRow.swift`
- Modify: `CrateAgent/Views/SettingsView.swift` (Auto-Tag pane)
- Test: `CrateAgentTests/AutoTagReviewRowModelTests.swift` (test the row view-model, not SwiftUI rendering)

**Interfaces:**
- Consumes: `AutoTaggerService`, `AcoustIDKeyStore`, `TitleMatcher`, `OperationEngine.applyBatch`, `SeratoWatchdog`.
- Produces: a row view-model `AutoTagRowModel` holding per-field include flags, the `TitleChoice`, and a method `payload() -> ApplyMusicBrainzMatchPayload` assembling the confirmed fields; `AutoTaggerView` that applies all confirmed rows in one `applyBatch`.

- [ ] **Step 1: Write the failing test** for `AutoTagRowModel.payload()` — defaults from `TitleMatcher`, toggling a field off omits it, title choice drives the title value.

```swift
func testPayloadHonorsFieldTogglesAndTitleChoice() {
    var model = AutoTagRowModel(candidate: candidateWithBaseMatch)   // tier .baseMatch → title default .merge
    XCTAssertEqual(model.payload().title, "Foo Song Title [DJ foobar remix - radio version]")
    model.includeAlbum = false
    XCTAssertNil(model.payload().album)
    model.titleChoice = .keep
    XCTAssertEqual(model.payload().title, model.candidate /* current */ .currentTitle)
    // identity always present regardless of toggles:
    XCTAssertEqual(model.payload().recordingMBID, candidateWithBaseMatch.recordingMBID)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme CrateAgent test -only-testing:CrateAgentTests/AutoTagReviewRowModelTests`
Expected: FAIL.

- [ ] **Step 3: Implement `AutoTagRowModel`** (plain struct/class, no SwiftUI) with the include flags initialized from `TitleMatcher.decide` + "field differs" checks, and `payload()` assembling identity (always) + chosen display fields.

- [ ] **Step 4: Run test to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Build the SwiftUI layer** (no unit test; verified by build + manual smoke). Model `AutoTaggerView` on `LibraryHygieneView`: `.task`-driven, `SeratoRunningBanner` when `seratoWatchdog.isSeratoRunning`, a `List` of `AutoTagReviewRow` (confidence chip, per-field `current → proposed` with toggles, a segmented **Keep / Merge / Take** title control enabled per tier, a "pick a different release" disclosure updating album live), and a footer with "Confirm all strong matches", select-all/none, and **Apply**. Apply builds `[.applyMusicBrainzMatch(row.payload())]` for confirmed rows and calls `operationEngine.applyBatch(_, batchId:)`. Add the `autoTag` case to `MainWindowView.Section` (displayName "Auto-Tag", an SF Symbol icon) and its detail view. Add the Auto-Tag **Settings** pane: a `SecureField` bound through `AcoustIDKeyStore` and an empty-state hint linking to acoustid.org when no key is set.

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild -scheme CrateAgent build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
swiftformat CrateAgent/Views/
git add CrateAgent/Views/AutoTaggerView.swift CrateAgent/Views/AutoTagReviewRow.swift CrateAgent/Views/MainWindowView.swift CrateAgent/Views/SettingsView.swift CrateAgentTests/AutoTagReviewRowModelTests.swift
git commit -m "feat(sp2): Auto-Tag review panel + Settings API-key pane"
```

---

## Task 15: Full verification + manual smoke test

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite (CI-equivalent).**

Run:
```bash
cargo test --manifest-path rust-core/Cargo.toml
cargo clippy --manifest-path rust-core/Cargo.toml -- -D warnings
cargo fmt --manifest-path rust-core/Cargo.toml --check
xcodebuild -scheme CrateAgent test
```
Expected: all green, no clippy warnings, no format drift.

- [ ] **Step 2: Manual smoke test** (per the spec's "no E2E network test in CI"). With a real AcoustID key entered in Settings and Serato **closed**: select ~5 known tracks (include one with a `(Dirty)` title and one with a wrong year) → Auto-tag → verify confidence, the title default (merge/keep) is correct, "pick a different release" updates album, year shows the original year → Apply → confirm the file tags changed (read with another tag editor) and History shows one batch → Undo → confirm tags revert exactly.

- [ ] **Step 3: Serato-gating smoke test.** Repeat a single apply with Serato **open**: confirm the "N Serato updates queued" banner, that file tags still change, and that the Serato-DB update drains when Serato quits.

- [ ] **Step 4: Final commit if any fixups were needed; otherwise done.**

---

## Self-Review (completed by plan author)

- **Spec coverage:** data model/migration → T1; encode_fingerprint gap → T2; year write gap → T3; fingerprint→base64 bridge → T4; models → T5; rate-limit/cache → T6; AcoustID → T7; MusicBrainz → T8; default release → T9; title tiers → T10; Keychain/settings key → T11/T14; mutation + inverse → T12; orchestration/classification/failure isolation → T13; review UI + per-field + title control + Serato banner → T14; testing + manual smoke → T15. The year→Serato-DB limitation is intentionally deferred (issue #95).
- **Placeholder scan:** no TBD/"handle errors"/"similar to" — each code step carries real code; UI SwiftUI body (T14 Step 5) is specified structurally because it is assembly over already-tested units, with its logic extracted to the tested `AutoTagRowModel`.
- **Type consistency:** `MatchCandidate`, `ApplyMusicBrainzMatchPayload`, `TitleDecision`/`TitleChoice`, `RowState`, `LookupError` are defined once and referenced consistently across tasks.
