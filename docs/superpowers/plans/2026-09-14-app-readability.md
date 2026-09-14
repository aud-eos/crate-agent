# App Readability and Auto-Tag Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement tasks with independent review gates.

**Goal:** Consistent comfortable/compact UI throughout the app, plus persistent Auto-Tag review with browsing and recording alternatives.

**Architecture:** Share native SwiftUI presentation primitives and one density preference. AppServices owns AutoTagSession, which owns navigation-independent scan/review/apply state. Alternative recording references and lazy MusicBrainz details stay in the lookup layer, separate from editable review decisions.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 14+, GRDB, existing Rust FFI (unchanged).

**Spec:** `docs/superpowers/specs/2026-09-14-autotag-review-ui-design.md`

## Global Constraints

- All writes continue through OperationEngine. Approval never applies automatically.
- Comfortable default; Compact changes layout only. No whole-library materialization or eager recording-detail fanout.
- File review uses original embedded tags and freshness snapshots, never substitutes Serato metadata.
- No secrets read or printed. No application service bootstrap or hosted Swift tests against the personal library.
- Use `/private/tmp/ui-logic-tests/CrateAgentLogic.xcodeproj` scheme CrateAgentLogic with AppLauncherTests excluded; production build-only separately.
- Tests exercise real state/client behavior and reproduce regressions before implementation; format changed Swift only.
- Commit explicit paths on feature/autotag-review-ui. Do not modify main or user-owned AGENTS.md. Independent review before push.

## Task 1: Shared style and adoption outside Auto-Tag

**Files:** Create `CrateAgent/Views/Components/AppPresentation.swift`, `CrateAgent/Models/WhitespacePreview.swift`, `CrateAgentTests/WhitespacePreviewTests.swift`; modify existing Views except AutoTag*.swift. Settings and MainWindow own density controls.

**Interfaces:** `AppDensity: String, CaseIterable { case comfortable, compact }`, `AppPresentation.densityPreference = "appearance.density"`; shared `PageHeading`, `TrackHeading`, `MetadataComparison`, `ActionBar` views. Density reads the same AppStorage key everywhere. `WhitespacePreview(current:proposed:)` exposes visible current/proposed strings and change description; it never changes mutation values.

- [x] Write formatter tests: leading/trailing spaces, tabs/newlines, combined changes, unchanged values, whitespace-only to empty. Example: `XCTAssertEqual(WhitespacePreview(current: " Track ", proposed: "Track").summary, "Remove leading and trailing spaces")`.
- [x] Run tests before implementation and record failure; implement the pure formatter then rerun.
- [x] Build shared views with semantic colors and readable system text; use `@AppStorage(AppPresentation.densityPreference) var density: AppDensity = .comfortable` and computed spacing.
- [x] Adopt across Library, Organize, all Cleanup tabs, History, Settings, onboarding, migration/rename sheets, banners/activity/menu-bar. Keep native tables and existing action semantics. Whitespace preview exposes invisible characters with a legend and accurately counts field fixes.
- [x] Build isolated target and test formatter; format only changed files. Save task report, then independent review before task completion.

## Task 2: Recording alternatives and explicit match assessment

**Files:** Modify Models/MusicBrainzModels.swift, Services/AutoTaggerService.swift, Services/MusicBrainzClient.swift and corresponding tests; create Services/RecordingAlternatives.swift if separation improves readability.

**Interfaces:** `RecordingAlternative` stores requested recording ID, source AcoustID ID and score. Alternatives are retained per file independently of successful selected candidate. Lightweight details include canonical ID, credited artist, title, disambiguation and duration. Existing `MusicBrainzLookupClient` adds a details method with a default implementation for compatible test clients. `AutoTaggerService` exposes paged detail loading and candidate resolution for a specified returned alternative. Initial and alternate candidates call the same assembly helper.

- [x] Write real decoder/service tests for all returned IDs, highest-score/source dedup, stable sorting, same-result shared scores and low-score retention. Preserve initial alternatives when first candidate has no releases.
- [x] Write lightweight-detail response/cache tests, canonical aliases, absent duration/disambiguation, one-page-at-a-time and visible errors/retry. Existing requester owns rate limiting and cancellation.
- [x] Implement alternatives without changing thresholds. Factor candidate assembly so selected ID/source and complete releases match the selected recording while original fingerprint/freshness/tag baseline is retained.
- [x] Verify a selected different recording updates payload identity and defaults; selecting same canonical ID does not destroy review decisions. No-result and no-usable-release states remain explicit.
- [x] Run targeted tests red/green and mutation checks; independent task review.

## Task 3: App-owned session and paged browse

**Files:** Create Services/AutoTagSession.swift, Services/AutoTagFileBrowse.swift, corresponding tests; modify AppServices.swift and AutoTaggerView.swift to move state/actions from the view into the session.

**Interfaces:** `@MainActor final class AutoTagSession: ObservableObject` owns searchState, browse filter/page, selected/scanned IDs, rowModels, confirmed/applied IDs, focusedFileID, scan task and apply/recovery state. Views observe the same instance owned by AppServices. `AutoTagBrowseFilter` cases either/missingMetadata/unmatched; query returns bounded 200-row pages and count using current files/linked tracks.

- [x] Write DB tests with null/empty/whitespace metadata, missing/identified track links, duplicates across pages, >200 rows and both filter predicates. Search and browse selections accumulate only through explicit page/row selection.
- [x] Write session tests using controlled real Tasks: view detach/reattach preserves state and scan continues; late old-scan result cannot repopulate reset; Stop retains completed rows and terminates pending status; apply completion/error survives navigation and cannot double-apply.
- [x] Move existing actions into session, replace local State with bindings, remove navigation-triggered cancel. The session observes results while view is absent and never recreates existing edited models on ordinary service updates.
- [x] Add tests for focus next/unapproved wrap, pending/all-approved/no-match cases, switching modes preserving edits, and field/release/recording edits clearing approval. `approveAndAdvance()` stages only; apply is separate.
- [x] New Scan confirms discard; Stop invalidates obsolete requests without clearing finished models. Disable candidate replacement while applying and retain partial-sync batch IDs.
- [x] Run targeted and mutation tests; independent task review.

## Task 4: Auto-Tag List/Focus and chooser integration

**Files:** Modify AutoTaggerView.swift and AutoTagReviewRow.swift; create AutoTagRecordingChooser.swift and AutoTagFocusView.swift as needed. Update MainWindow activity display to observe session progress.

**Interfaces:** All review decisions bind to AutoTagSession. Shared field editor renders either list cards or Focus; the chooser pages detail requests and resolves chosen recording using Task 2 APIs guarded by session generation/request identity.

- [x] Use shared Comfortable/Compact primitives. Heading artist/title first; filename secondary. Distinct audio score and explanatory ambiguity labels; no misleading Strong/Weak chip. No claim that score validates all tags.
- [x] Current/Proposed values and live title result; unchanged disclosure retains access to all controls; unavailable proposals disabled. Explicit Approve/Approve & Next, Previous/Next, Apply approved tracks (N).
- [x] Browse untagged default either condition, with separate filter and Search. Bounded pages and state persistence; loading/error/empty states always visible.
- [x] Chooser loads ten details per page, shows all returned alternatives including lower scores, retries failed entries, collapses known canonical aliases and keeps old proposal on failed switch. Opening/closing does not approve or reset edits.
- [x] Verify task cancellation and selection races in session tests. Build production app without launch; render fixture-only snapshots where possible for both modes/densities and long/empty text.
- [x] Independent review plus full isolated Swift suite; scoped format and diff check. Update README usage and behavior docs, push feature branch, create PR. Do not merge.

## Completion evidence

Record each task's files, test commands/results, reviewer verdict and commit in an ignored ledger. Cover all spec sections in final review, including secondary screens and navigation during Apply. A passing isolated suite is not a live-library smoke test; report that visual verification limit honestly.
