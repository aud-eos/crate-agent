# App-wide readability and Auto-Tag workflow

## Shared visual design

Apply a consistent native macOS style across Library, Organize, all five Cleanup
panels, Auto-Tag, History and Settings. Include onboarding, rename/migration
sheets, shared banners, the activity strip and menu-bar status so secondary
surfaces retain the same vocabulary and hierarchy.

Comfortable is the default density; Compact is an app-wide preference persisted
between launches. Put the control in the main toolbar and expose the same setting
in General settings. Both controls edit one preference. It adjusts row padding,
control spacing and secondary detail density, not the underlying information or
selection state. Compact must still have legible text and usable hit targets.
List/Focus is a separate Auto-Tag presentation choice.

Use system typography with readable body text for values, larger headings for
track identity, and secondary text for filenames, paths and explanation. Reserve
monospaced text for technical input such as filename templates and aligned
numeric counts. Avoid tiny all-caps field labels and decorative quotation marks.
Support light/dark appearance, system contrast settings and VoiceOver labels;
status must not rely on color alone.

Shared components should cover page headings with a short task explanation,
track identity headers, Current/Proposed comparisons, empty/loading/error states,
status badges and bottom action bars. A shared density style supplies the spacing
and sizing values. Components share presentation mechanics, while each screen
keeps its distinct operation and validation rules. Do not force a table, grouped
duplicate chooser and settings form into the same layout.

Keep the main action predictable: selection/result count and feedback on the
left, secondary actions and one explicitly named primary action on the right.
Use wrapping or a two-row layout at narrow widths; do not shrink text to fit all
controls. Action labels state what will happen and how many items are affected.
Counts distinguish field fixes from tracks when they differ. Respect existing
selection and confirmation rules; a visual refresh must not broaden write scope.

## Screen-specific readability

- Library: retain its bounded native table, with readable rows, clear search and
  sorting controls, and secondary path access. Density changes do not reset
  selection, sort order or search and do not expand the fetched row cap.
- Organize and migration: show the track first, then labeled current/proposed
  filename or location. Separate conflicts and unavailable actions from valid
  moves, using text as well as color. Keep full paths accessible without forcing
  them into every heading.
- Cleanup: explain the selected cleanup operation above its results. All five
  panels use consistent result hierarchy and action bars. Current and Proposed
  values align and wrap without clipping. Duplicate groups retain their keeper
  selection and removal safeguards; case and missing-field panels retain their
  distinct editing controls.
- Whitespace: render spaces/tabs/newlines with visible markers in the change
  preview and an explanatory legend, with readable descriptions such as Remove
  leading spaces, Remove trailing spaces or Normalize internal whitespace derived
  from the actual before/after values. Show Empty for empty results. The display
  formatter never modifies the underlying mutation values. Multiple kinds of
  whitespace edits must be described accurately rather than reduced to a false
  single cause. Name the action Apply N whitespace fixes.
- History: make operation, affected track/batch, time and outcome distinguishable
  at a glance. Undo and recovery retain existing eligibility and error handling;
  visual polish does not imply the open undo/re-sync defects are fixed.
- Settings and secondary surfaces: use consistent headings, readable help text,
  spacing, control labels and feedback. Preserve native controls and existing
  credential storage; do not expose secret values in previews or logs.

## Delivery and verification of shared style

Implement shared styling and comparison components first, then adopt them across
all listed surfaces. Keep Auto-Tag's session/chooser behavior in separate focused
components and commits within this work, so functional changes can be reviewed
independently from style adoption. Complete the full agreed scope, not just the
two screens shown in the screenshots.

Use fixture-only visual checks for both densities, light/dark appearance, long
track names and paths, blank values, errors and narrow windows. Never launch the
normal app host against the user's library for automated screenshot collection.
If fixture rendering is unavailable, rely on build checks and have the user
verify the built app's appearance. Add behavior tests for whitespace display
formatting and preference/state preservation; do not write tests that merely
assert particular font or padding constants.

## Goal

Make Auto-Tag results readable and explain what the app knows before the user
approves changes. Support quick comparison across tracks and detailed review of
one track. Let the user inspect every recording ID returned by their AcoustID
lookup and select a different recording without rerunning the audio lookup.

This changes review presentation and in-memory candidate selection. Existing
OperationEngine mutation, undo, freshness validation, and Serato queuing contracts
remain the apply boundary. The open write-safety issues from PR #98 remain open.

## Agreed interaction

- A List / Focus segmented control switches presentation without resetting any
  review edits, approvals, recording selections, or release selections. Default
  to List and persist only that display preference across launches. All other
  session state survives navigation within the running app.
- List uses readable track cards with artist and title as the heading. Filename
  is secondary and available in full through a disclosure/help affordance.
- Focus shows one track with larger text, Previous/Next navigation, and its
  position within this scan. Approve & Next stages the current match and advances
  to the next resolved, unapproved, unapplied match in scan order, wrapping once.
  If none exists, stay on the current track and show that no ready matches remain.
  Pending lookups are distinguished from completed review; their arrival does not
  unexpectedly move focus. Previous/Next can inspect all scan entries, including
  no-match and failed entries, and is disabled at the ends.
- Both views share the same editor and review state, keyed by file ID. Switching
  to Focus initially selects the last focused entry if it still exists, otherwise
  the first unapproved ready match, otherwise the first scan entry.
- Approval is an explicit labeled action, distinct from field choices. Approval
  stages changes only. Apply approved tracks (N) remains the explicit action that
  writes through the existing engine. Auto-advance never applies changes.
- Applied entries remain visible and read-only. Controls that change a proposal
  or its approval are disabled during Apply.

## Browse without a search query

The selection stage also offers Browse untagged alongside Search. Opening the
browser shows a bounded page without requiring any text input. It never starts
AcoustID lookup, fingerprints a selected batch, or writes tags merely by opening.
Next/Previous pages replace the visible rows instead of accumulating the entire
library in memory. Select this page adds only the visible page (at most 200 files),
while explicit selections persist across pages and search queries. Scan selected
(N) always shows the exact requested count.

The default includes files missing artist, title or album in the indexed library
OR lacking a MusicBrainz recording ID on their current linked track. Treat null,
empty and whitespace-only values as missing. Offer separate Missing library
fields and Not matched to MusicBrainz filters as well as the default Either.
Use current rows and links, never the presence of historical match events.

The database's display fields mirror Serato and cannot be presented as freshly
read embedded tags. Label the missing-fields condition as missing library fields,
with a brief explanation that live embedded tags are read during scanning.
Do not read every audio file merely to open this browser. A sibling file may
already share an identified track; this is a recording-identity filter, not a
claim that this particular file's embedded tags have been written.

Use a stable query order with file ID as a tiebreaker. Page/filter changes discard
obsolete async responses. Empty results and query errors remain visible. Cover
multi-page traversal, page selection, late responses, and selection persistence
with temporary-database and session-state tests.

## Readable field comparisons

Use native macOS text sizes and semantic colors with clear spacing. Each changed
field shows Current and Proposed values plus the value that will be saved when
the user chooses to retain the current value. Avoid decorative quote marks and
monospaced body text. Empty tags say Not set.

Keep existing title semantics but label choices Keep current, Merge, and Use
suggestion, with a live result preview. Merge remains available only when the
existing TitleMatcher supports it. Artist, album, and year keep their existing
include semantics with explicit Apply suggestion controls.

Unchanged fields are grouped behind Show unchanged fields, preserving access to
their controls. Missing proposed values are shown as unavailable and cannot be
selected as an instruction to clear a field. No new no-op write suppression or
payload semantics are introduced by this display change.

Editing an approved proposal clears its approval, including field choices and
release changes. The user must approve the actual proposal that will be applied.
Merely expanding details, loading alternatives, or switching modes does not clear
approval.

## Explain matching without Strong / Weak

Show the AcoustID score separately as Audio match: 98%. Explain that this is the
lookup's fingerprint score, not a probability that the displayed tags are right.
Recording ambiguity gets its own label and explanation:

- Multiple plausible recordings: Review recording choice.
- A single plausible recording above the existing threshold: Suggested match.
- A score below the threshold: Lower audio match — review carefully.

Preserve the existing 90% threshold and five-percentage-point competing-result
rule for bulk-approval eligibility. This work changes explanation, not matching
thresholds. Multiple recording IDs attached to one AcoustID result share that
result's score; do not imply independent per-recording scoring. A single plausible
recording does not imply a verified release, year, or remix/version label.

## Choose recording versus choose release

Choose recording opens a bounded, lazily loaded chooser for this file. It lists
all distinct recording IDs returned by the lookup, not every recording in
MusicBrainz and not only the candidates meeting the ambiguity threshold.

Preserve the AcoustID result ID and score associated with each recording. If an
ID occurs in several results, use its highest score and retain that result's
AcoustID ID. Sort by descending score with a stable recording-ID tiebreaker.
Explain which candidates meet the plausible threshold and which have lower
scores; lower-scoring candidates remain inspectable and manually selectable.

Each entry shows artist, title, recording disambiguation/version information and
duration when supplied, audio score, loading/error state, and whether it is the
current selection. Missing details stay visibly unknown. Metadata failures leave
the entry present with Retry; do not silently remove possible recordings.

Fetch lightweight recording details on demand in small pages (10 entries), using
the shared MusicBrainz requester, rate limiter, retry/cancellation behavior and
cache. More results remain accessible via Load more. Do not resolve every
recording and every release during the original scan or for every rendered card.
Existing complete-release loading is required only when a recording is selected
as an actual proposal. The already selected recording can reuse loaded details.

Resolve MusicBrainz redirects to canonical recording IDs. Merge known aliases as
their details arrive, preserving the highest associated score/source. Do not
claim unresolved IDs are distinct canonical recordings. Keep bulk approval
conservative while ambiguity remains unresolved; manually choosing one does not
automatically upgrade its confidence or approve it.

Selecting a different recording loads its complete metadata/releases, then
atomically replaces that file's proposal and clears approval. Show a notice that
changing recording resets field choices and release selection. Rebuild defaults
using the existing AutoTagRowModel logic against the original scan-time file
tags. Preserve fingerprint identity and the original freshness snapshot so that
loading metadata cannot make stale audio appear newly validated. Use the chosen
recording's associated AcoustID result ID and canonical MusicBrainz ID.

If loading fails or the recording has no usable release, show the reason and
retain the existing proposal and edits. Choosing the already selected canonical
recording is a no-op and does not reset edits. Choose release continues to select
an edition of the current recording using existing album/year rules.

## Session survives navigation

Source diagnosis: MainWindowView conditionally constructs AutoTaggerView for its
selected sidebar section. AutoTaggerView stores search, selected/scanned IDs,
row models, approvals, apply results and recovery state in local State, and its
onDisappear explicitly cancels the service. Navigation therefore discards the
review context even though AppServices owns the longer-lived lookup service.

AppServices will own a single AutoTag session model alongside its lookup service.
AutoTaggerView observes that session and renders it. Search text, browsing mode,
filter/page, selections, scan IDs/progress/results, edits, approvals, chosen
recordings/releases, List/Focus mode and focus location survive sidebar navigation
and closing/reopening the main window while the app remains running.

The session owns the scan task and observes incoming results independently of
whether Auto-Tag is visible. Navigating away must neither cancel the scan nor
reset candidate models when the user returns. Preserve edits on existing models
while adding newly resolved rows. Search/page tasks also belong to the session
or resume from retained state without leaving a permanent loading indicator.

Show ongoing Auto-Tag scan progress outside the panel in the app's activity
surface, with an explicit Stop scan action available when returning to Auto-Tag.
Stop cancels outstanding lookup work, keeps completed results and edits, and
labels remaining rows as stopped. New Scan is the explicit reset action; warn
before discarding an active scan or unapplied review decisions. Leaving the
screen is never equivalent to New Scan or Stop.

In-flight Apply and its result/error/re-sync batch ID must also be session-owned
so navigation cannot lose recovery information or allow the same batch to be
applied twice. App exit ends this in-memory session; durable restoration of a
review draft across relaunch is outside this change. Existing queue persistence
and recovery defects remain separately tracked.

## State and component boundaries

- Retain lookup alternatives separately from the selected resolved candidate so
  available alternatives survive even if the initial candidate cannot resolve.
  The chooser is accessible when lookup IDs exist but initial metadata failed.
  A true no-match result with no recording IDs has no chooser.
- Extract a shared candidate-assembly mechanic from AutoTaggerService so initial
  selection and alternative selection build identical identity/tag baselines.
  Keep network loading separate from the pure assembly and review-edit state.
- An app-owned session model owns search/browse state, row models, approvals,
  applied IDs, focus, scan work and apply/recovery state.
  AutoTaggerView uses it for both renderers and for the existing apply payloads.
  Avoid parallel copies of editable state inside cards or the chooser.
- Separate the shared field editor, List/Focus layout, match explanation and
  recording chooser into focused SwiftUI components. Keep presentation-specific
  expansion state local; all decision state lives in the session model.
- Use scan generation and per-selection request identity checks after awaits.
  New Scan, explicit Stop, or a newer recording selection invalidates obsolete
  responses. Sidebar navigation does not invalidate the session. Closing the
  chooser cancels its detail-page work. A completed stale
  request must never replace a newer proposal or repopulate a reset session.
- While a recording switch is pending, disable approval/apply for that file.
  Freeze candidate replacement while the apply operation holds its payload
  snapshot; asynchronous chooser work cannot change an applied row afterward.

## Verification

Use TDD for the state and loading mechanics. Tests must exercise production
candidate assembly, session transitions, request cancellation/generation guards,
and real client decoding/cache behavior rather than stub those mechanisms.
Supply deterministic network responses at the transport boundary and temporary
in-memory databases. Confirm regression tests fail with the relevant fix removed.

Cover deduplication/ranking, shared scores, low-score alternatives, canonical
aliases, paged detail loading and retry, missing duration/disambiguation,
no-release candidates, and selection payload identity. Verify title/album/year
defaults preserve the original file snapshot across recording switches.

Cover List/Focus shared edits, approval invalidation, wraparound auto-advance,
all-approved/pending/no-match states, re-scan reset, applied-row immutability,
selection A finishing after selection B, and cancellation after New Scan.
Destroy and recreate the Auto-Tag presentation around the same production
session during a real task-controlled scan; verify results continue arriving,
edits/search/page/focus survive, and no second scan starts. Cover navigation
during Apply and external-sync failure so the completion and recovery state
remain available. Verify explicit Stop cancels while preserving finished rows.

Build the production app without launching it. Run the isolated Swift test harness
excluding the three unsafe AppLauncher tests tracked by #116. Rust is unchanged.
Format only changed Swift files. Obtain independent Astra review before pushing
the implementation PR. For visual verification, use fixture-only rendering if
available; otherwise the user verifies the built app. Never start services against
the personal library as part of automated verification.

## Scope boundaries

No automatic file writes on approval, full-library selection, playback, arbitrary
MusicBrainz search, manual recording-ID entry, matching-threshold changes, database
migration, or redesign of shared canonical ownership is included. Keep the existing
cap on Auto-Tag search results and lazy list rendering to avoid reintroducing the
large-library UI freeze.
