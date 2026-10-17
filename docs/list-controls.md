# List controls

Track lists search artist, title, album, and filename/path where available. Search
is literal and Unicode case-insensitive, including canonically equivalent text;
`%` and `_` are ordinary characters. Clear search resets only the filter. Searching
never starts audio lookup, rescans the library, or writes files.

Batch lists open with nothing selected. Select all eligible matches selects a
snapshot of the current search/filter results, including rows outside the
viewport. Its mixed checkbox indicates a partial selection; turning it off
removes only that scope. Clear selection removes the entire session selection,
including hidden rows. Result, selected, and hidden counts remain visible.

Sorting, searching, and filtering preserve deliberate selections. Rescans retain
unchanged eligible proposals; changed, removed, or newly ineligible selections
are removed with a notice. Newly arriving rows never become selected. A different
operation context, such as another missing field or duplicate mode, starts empty.
Leaving a screen may end its local session; returning never selects results for you.

Actions use the explicit selection, including selected rows outside the filter.
Selection and proposal controls freeze during apply. Existing Serato guards,
confirmations, progress, event history, and recovery remain in effect. Selecting
rows does not approve a tag proposal or start an operation.

| Surface | Selection and action scope |
| --- | --- |
| Cleanup: Missing | Select missing fields to fill. Changing the field starts empty; editing the fill value deselects changed proposals; filtering does not. Rescan does not switch fields. |
| Cleanup: Find & Replace | Select field replacements. A separate result search filters the preview; editing replacement inputs reconciles unchanged proposals and removes changed selections. Apply waits for the current preview. |
| Cleanup: Whitespace | Select individual field fixes; no implicit apply-all. |
| Cleanup: Case | Select groups to apply. Choosing the canonical spelling is separate from including a group in the batch. |
| Cleanup: Duplicates | Select groups to resolve; each retains one keeper. Clear selection never clears keeper choices. Single-group Trash remains an explicit confirmed action. Trash recovery remains Finder-based. |
| Organize | Select eligible move proposals. Missing required metadata stays visible but unselectable. Search combines with the location filter. |
| Auto-Tag selection | Both browse and search are paged. **Select page** affects the current page's eligible files; selections survive page and query changes. The count outside this page includes selections hidden by search. |
| Auto-Tag review | List search filters display only. Approvals remain separate, with total and hidden approval counts. Explicit bulk approval controls and Apply approved tracks cover the entire scan; Focus mode navigates the whole scan. |
| Library | Continuous scrolling covers every match. Select all matches and Command-A capture the full query, including unloaded rows. Selection survives search, sort and status changes; total and outside-filter counts stay visible. Changed membership revisions and deleted files are deselected with a notice. Right-click Rename, History and Finder resolve the clicked file afresh; selection does not introduce a bulk mutation. Song families show one main row; see [song families](song-families.md#library). |
| Move library | A whole-library operation that changes the watched root after successful completion. Search filters its preview only; confirmation always states the complete move count. Partial selection would violate that operation's contract. |

Flat Cleanup and Organize previews use native reusable rows and continuous
scrollbars. Click column headers to sort; Space toggles the focused row and
Command-A selects eligible matching results. The shared density preference still
controls spacing. Case and duplicate groups keep their choices visible in cards;
there are no expandable rows or disclosure sections.

## Development contract

`ListResultSelection` owns immutable result identities, selected IDs, filtering,
sorting, and proposal/revision reconciliation. `ListSearch` supplies matching for
in-memory lists and the registered SQLite function. `ListSearchField`,
`ListResultSummary`, and `BatchSelectionControls` share presentation, while each
screen owns its scan, domain eligibility, approval, and apply orchestration.
Organize retains its indexed immutable snapshot for its larger planning workload.
Library uses `PagedResultsController` with a GRDB read snapshot and a bounded
five-page cache. `PagedTable` renders native reusable rows and loading placeholders;
`PagedSelectionController` delegates captured IDs/revisions to ephemeral SQLite
storage. Count, page and selection errors remain visible with Retry. Selection
capture completes atomically before dependent controls become available. Clear
selection cancels unfinished capture as well as clearing hidden selections.
Never interpret a viewport, page, or current filter as the complete selection.

Future artist, crate, version, and playlist lists should adopt these mechanics
when implemented. Preserve domain-specific choices and ordered playlist semantics;
new imports or alternates must never expand a previous selection automatically.
Future grouped lists must keep controls and counts visible without disclosure UI.

Verification uses the isolated Test host, synthetic data, native keyboard and
accessibility checks, a 2,524-row Missing regression, exact persisted batch targets,
and the existing 50,000-row Organize responsiveness fixture. See [testing](testing.md).
