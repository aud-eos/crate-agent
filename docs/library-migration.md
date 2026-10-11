# Library migration

Move library preserves each file's relative path under a new root. Previewing
captures the library membership revision and the source file's physical change
stamp. Applying validates both inside the operation engine's serialized writer,
before moving audio. Retirement, retire/reactivate cycles, unavailable audio,
replacement files, and edits after preview invalidate the planned move.

Each file uses the same compensated physical-move transaction as Organize. If its
database transaction fails, the move is reversed when the audio's ownership can
still be verified. A destination changed by another process is preserved and the
failure is reported rather than overwriting or deleting unowned audio.

Successful files share one History batch and one coalesced Serato update pass,
covering database V2, Subcrates, and SmartCrates. Undo reverses the successful
moves. Rejected files stay at their original locations and receive no rename event.

## Partial completion and recovery

- When individual files fail, the sheet reports moved/skipped counts and errors;
  additional errors are logged to Activity. The library-folder preference stays
  unchanged. Re-scan after addressing the errors, or undo the completed moves in
  History.
- Re-scanning a destination nested inside the old root excludes files already
  moved into that destination; it does not nest the destination a second time.
- If the physical moves and database commits succeed but Serato writes fail, the
  error identifies the applied batch. Use History's re-sync action to finish its
  Serato writes, or undo the batch. Do not blindly reapply the original preview.
- If Serato starts during migration, Serato writes are deferred through the
  existing operation-engine queue.
- The sheet changes the watched-folder preference and requests a restart only
  when migration returns without failures and no non-retired files still need
  migration from the old root. Unavailable files count toward that check even
  though they cannot be selected for processing. Following external-write recovery,
  review the paths before changing the watched folder in Settings.
