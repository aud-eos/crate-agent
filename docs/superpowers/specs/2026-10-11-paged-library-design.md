# Full-library browsing with bounded paging

Status: approved by the owner on 2026-10-11. Implements #134 on top of #146 / PR #154.

## Intended outcome

Library exposes every matching file through one continuous native scrollbar.
Opening a 30,000–50,000-file library, jumping to a distant row, searching, sorting,
and selecting must remain responsive without decoding or retaining every row.
Keep existing Library columns, status filters, rename/history/Finder actions,
density, accessibility, and drag-and-drop import.

The issue already approves AppKit NSTableView with a generic paged source. This
spec makes the consistency, lifetime, and selection rules explicit. The newer
#146 contract supersedes #134's original instruction to clear selection when the
query changes: deliberate selections survive search, sort, and filter changes.

## Approach and alternatives

Use AppKit's indexed data source, GRDB's existing SQLite snapshot support, and
SQLite LIMIT/OFFSET with a deterministic ID tie-breaker. No new dependency is
needed. Reuse existing column/cell and list-control mechanics where identical;
keep checkbox batch previews and native Library row selection separate.

Loading all lightweight rows into the existing preview table would remove the
visible cap but fail the bounded-decoding requirement. A fully custom scrolling
implementation would duplicate AppKit's scrollbar, keyboard, focus, and cell
reuse behavior. Neither is the chosen approach.

## Boundaries

1. A generic paged query contract has an immutable query signature, total count,
   asynchronous range loading, stable row identity, and selection snapshot
   operations. It has no dependency on BrowserRow or Library SQL.
2. A main-actor paged result controller owns the active generation, visible range,
   bounded cache, in-flight requests, errors, and selection. It schedules reads
   away from the main actor and publishes only accepted results.
3. An NSViewRepresentable table bridge requests rows by index, renders loading
   placeholders on cache misses, reports visible ranges, and reloads changed
   ranges. It accepts column descriptors and context actions from its adapter.
4. A Library adapter supplies BrowserRow projection, status/search predicates,
   database sort descriptors, refresh observation, identity/revision checks, and
   the existing row actions. Move SQL ordering out of LibraryBrowserView.

The existing immutable Organize/Cleanup previews remain usable. The paged layer
must work with a second test row type without changes to its internals; moving
other product screens to database paging is outside this first adoption.

## Query consistency and lifetime

Count and page reads in a generation use one read snapshot, not independent
reads of a changing database. Production uses GRDB DatabaseSnapshot from the
existing WAL pool. The integration fixture uses a task-owned temporary WAL
library so it exercises the real snapshot path; pure paging tests use a fake
query boundary with controlled completions.

Observe the columns affecting membership, display, eligibility, and ordering,
including metadata-only changes. Coalesce refresh requests. Each accepted
refresh creates a new generation and snapshot, cancels obsolete work, and
invalidates old cached positions. Count failure and page failure are distinct
visible states with Retry; a failed page never masquerades as an empty result.

Release old snapshot readers once cancelled requests finish. Do not keep a
library read transaction alive solely to remember a long-lived selection. On
navigation away, cancel page loads and release the browsing snapshot/cache.
Search/sort/filter changes reset the viewport to the first result. Database
refreshes anchor the viewport and focused row by stable ID where possible; if
that row disappears, focus the nearest surviving position without selecting it
as a replacement batch target.

## Paging and native rendering

Start with 200 rows per page and at most five cached pages (1,000 decoded rows).
The window covers visible pages and adjacent prefetch pages. Distant scrollbar
jumps replace the window directly. If a viewport needs more rows than this
window, bound the effective page size from viewport height so it still fits in
five pages; record both effective size and cache bound in diagnostics/tests.

Coalesce requests for the same page. Limit concurrent reads, prioritize visible
pages, and evict out-of-window pages even when old requests complete late.
Generation and request checks prevent old results or errors from publishing.
The table's row count represents the complete query from the start. Cache misses
show stable, inaccessible-to-actions placeholder cells immediately.

Use native header sorting over the full SQL query. Keep native multi-selection,
keyboard navigation, density, alternating rows, light/dark rendering, and
accessible names. Table focus and selected file identities are separate state.
A placeholder can receive navigation focus; its actions and identity-dependent
selection wait for its row to load and are cancelled if the generation changes.

## Selection

Initially nothing is selected. Ordinary selection uses stable IDs, never viewport
positions. Select All N Matches and Command-A include unloaded matches from the
captured query generation; scoped deselection removes that scope. Clear selection
removes the entire session selection. Show total selected and outside-filter
counts, with a mixed state for partial scope coverage.

The generic representation supports explicit selections and captured all-matching
sets with exclusions. A capture fixes identity/revision membership at the time of
selection. Re-running a live predicate is not sufficient: newly imported rows or
existing rows that later start matching must not join an earlier selection.

The Library provider freezes bulk membership off the main actor in bounded,
identity-only batches. An ephemeral SQLite selection store holds large captured
sets; UI updates query counts and membership for visible IDs instead of decoding
all selected IDs. It does not modify the library schema or domain rows. Release
capture resources when cleared or when the screen's selection session ends.
Snapshot capture and reconciliation expose progress/failure; dependent controls
are disabled while their scope is unresolved. Never publish a partial capture as
successful Select All.

Refresh reconciles deleted and changed membership revisions without transferring
selection to adjacent rows; report removed selections. Search/filter/sort changes
preserve selections, show hidden counts, and do not rewrite their captured scope.
A future consequential bulk action must resolve exact current eligible targets
from the capture, show the final count, and use OperationEngine. This work adds
no Library bulk mutation action. Existing single-row context actions resolve the
clicked stable ID afresh and preserve their existing eligibility checks.

## Delivery and validation

Keep three reviewable units, as requested in #134:

1. Generic query/controller/cache/selection contracts and deterministic tests.
2. Native table bridge, placeholder/prefetch behavior, keyboard and rendering tests.
3. Library adapter, observation, existing actions, cap removal, and usage docs.

Complete all three for this task; choose branch/PR dependencies in the written
implementation plan. Do not remove the cap before the production-size checks pass.

Use one deterministic temporary WAL fixture with at least 30,000 rows. Prove:

- Initial load and distant jumps decode only the bounded page window.
- Traversing first/last/back cannot grow the cache beyond its declared bound.
- Count/pages stay consistent across inserts, deletions, and metadata changes.
- Old query responses cannot populate a new query, including cancellation races.
- Search and sort cover the complete result with no duplicated page boundaries.
- Explicit/all-matching selection, exclusions, hidden clearing, and refresh preserve
  captured membership; new matches never become selected implicitly.
- Keyboard navigation and context actions resolve the correct ID after paging.
- Errors remain visible and retryable. Loading, empty, and no-match states differ.
- A second row type exercises the same generic paging machinery.

Record initial render, distant jump, maximum main-thread delay, decoded-row count,
and peak cache size in the PR. Target under 100 ms for rendering placeholders and
under 50 ms for main-thread work on the fixture; report measured asynchronous page
latency separately. Run the documented isolated Swift suite, Rust tests/Clippy,
formatters, and diff checks. Do not access the owner's library or start a dev server.

Update README and docs/list-controls.md to remove the Library cap exception and
explain full-query selection. Preserve the no-disclosure UI rule throughout.
