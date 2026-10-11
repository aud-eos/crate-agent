# Organize

Organize previews moves into `<MusicFolder>/<ArtistLetter>/<Filename>` using the
filename template in Settings. Opening the screen only reads the library and
computes proposed paths. It does not move audio or write Serato files.

The preview loads in the background. **Cancel scan** or leaving the screen cancels
that request; an obsolete request cannot replace a newer result. Cancelling a
rescan retains the previous preview. Planning errors remain visible beside Rescan.

## Required metadata

Artist and Title must both be present, even when the filename template omits
one of them. Other supported tags become required when the template references
them: Album, Genre, BPM, Key, Comment, Label and Length. Nil, empty and
whitespace-only values are missing. `$ext` comes from the file path, and escaped
text such as `$$album` is a literal, not a metadata requirement.

Files lacking required tags stay visible with a **Needs Artist**, **Needs Title**,
or other missing-field status. They have no proposed destination or selection
checkbox. The footer counts blocked files across the preview and in the current
filter. Correct their tags in Library Cleanup or Auto-Tag, then rescan. Repaired
files do not become selected automatically; selected files that become blocked
are deselected with a notice.

These checks use indexed metadata; opening Organize does not read embedded tags
or infer artist/title from a filename. The existing filename is only a display
fallback. Apply checks the plan's required tags again inside the move transaction.
If a required value became blank, that file stays in place with no move event and
an explicit failure reason. Other eligible selected files can still move.

## Review and selection

- The default filter shows files outside the music folder. **All** also includes
  proposed moves and blocked files inside it.
- The native table scrolls through every matching proposal. It has no result cap
  or next-page button. Resize columns or hover over a path to read its full value.
  Comfortable and Compact density both apply to the table.
- Nothing starts selected. Check individual rows, or use **Select all N eligible matches**
  to select every eligible result in the current filter, including rows outside the viewport.
  The checkbox shows a mixed state for partial selection; clicking it selects the
  remaining matches. Unchecking it clears only that filter's selection.
- Arrow keys move row focus. Space toggles the focused row's checkbox; Command-A
  selects every eligible match in the current filter. Row focus alone does not select a file
  for moving. Checkboxes have accessible track labels.
- Changing filters preserves selections. The footer shows the total selected and
  how many lie outside the current filter. **Clear selection** clears both visible
  and hidden selections.
- Rescanning preserves a selected proposal only if its file, membership revision,
  source, destination and required fields still match. Changed or removed proposals are deselected
  with a visible notice. New proposals never become selected automatically.

**Move N selected files** confirms the complete selection, including the hidden
count and destination folder. Filtering and selection freeze during a scan or
move. Serato must be closed to start organizing. Existing OperationEngine checks
validate each original proposal before its journaled move; successful moves form
one undoable batch in History. Partial failures appear in the result and activity
log. See [migration and recovery](library-migration.md) for apply-time validation.

## Large-library regression evidence

`OrganizePreviewTests` uses one isolated 50,000-file database, including 1,500
colliding destination names. It exercises the real background planner, cancellation
of a paused database read followed by a newer request, selection reconciliation,
exact apply targets, a native table jump to the final row, keyboard/checkbox
selection, and a rescan alongside the real fingerprint worker. Navigation and
planning leave the move event log empty and create no destination directory.

Run it with the isolated app host:

```sh
xcodegen generate
xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent \
  -configuration Test -derivedDataPath build-output/DerivedData \
  -only-testing:CrateAgentTests/OrganizePreviewTests test
```

The test prints `ORGANIZE_PERF` load, main-actor heartbeat, first-render and distant
scroll timings. It checks a maximum heartbeat gap of 250 ms, first render below
one second, distant scrolling below 250 ms, and fewer than 100 allocated row views.
The concurrent case verifies that successful real audio decoding overlaps the
scan, using 32 distinct 30-second WAV fixtures.
These are fixture regression bounds, not a guarantee for every machine or a
reproduction of the owner's original Force Quit.

Investigation at base `d097062` confirmed synchronous planning on the main-thread
process sample. An unsampled 50,000-row unique-path fixture took 454 ms to decode
and 533 ms to plan on the main actor. A separate 1,500-name collision fixture took
2.73 seconds and produced only 1,001 unique destinations because the old suffix
search restarted for each file and gave up after 1,000 attempts. The planner now
remembers each destination's next suffix and continues until it finds a unique
path, checking cancellation throughout.

After the fix, a local arm64 Test-configuration run loaded 50,000 proposals in
1.27 seconds both idle and alongside fingerprinting. The maximum main-actor
heartbeat gap was 12 ms in both cases. First render took 38 ms, jumping to the
final row took 9 ms, and only 17 row views existed. All 32 audio files completed
fingerprinting successfully.

The full immutable plan remains in memory because collision allocation needs the
complete candidate set. Only visible rows become AppKit views. SQL-backed paging
for other screens remains tracked separately in #134; shared selection adoption
outside Organize remains in #146.
