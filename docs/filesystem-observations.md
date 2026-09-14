# Filesystem observations

Filesystem events observe availability and location for existing file rows. They
never establish removal from Serato, retire a recording, or import unknown files.
Availability is independent of membership: an active file can be missing, and a
retired file can be available after a Finder restore.

`FileAvailabilityResolver` checks the recorded volume UUID against mounted volumes
before inspecting a path. An absent volume is offline; a missing path on an online
volume is missing. Permission failures are inaccessible. Other inspection failures
throw rather than inventing evidence of deletion. Native, volume-aware Trash URLs
and filesystem relationships identify Trash; an ordinary folder called `Trash`
remains an ordinary folder.

Positive Trash observations preserve the last normal path and emit only library
state observation events. A verified normal location for a retired file emits an
observation-only location event with its previous path, volume and inode in the
inverse. It preserves membership revision and has no Serato projection or Undo
action. Active normal moves continue through the guarded rename mutation.

A path becoming readable does not prove that the tracked file returned. Positive
availability also requires the stored inode and volume to match. A different file
at the same path requests reconciliation and keeps the original unavailable;
previously available rows become unknown until association is resolved. A genuine
same-identity restore can become available. Both inode and hash move candidates
require evidence that the original identity is absent at its previous location;
creating a hard link while the original remains present does not rename the row or
Serato references.

The watcher delivers batches and original kernel event IDs through one ordered
stream. `FilesystemEventProcessor` handles one batch at a time and checkpoints
only after success. Failed heads remain queued and block later checkpoints until
`retry()` succeeds. Each observation uses its kernel ID as its journal batch ID.
Replayed observations recover their existing journal projection before checking
the current path, including when a restart groups those IDs into different batches.
This matters when a rename committed its database row but an external rewrite failed.

Dropped events and directory renames set a coalesced reconciliation request; they
do not launch recursive scans or infer membership changes. The reconciliation
consumer uses the shared synchronization session. A failure stops processing and
publishes the failed event and error through the main-window/menu-bar sync status.
The failed head remains queued, later batches cannot pass it, and the prior kernel
checkpoint remains unchanged. Retry Sync replays that head with strict validation;
only successful replay and checkpointing clear the failure latch. A fresh normal
session then drains outbound writes and reopens processing readiness.
