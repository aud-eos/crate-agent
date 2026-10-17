# Reviewing Auto-Tag suggestions

Auto-Tag looks up the audio of tracks you select, then lets you review the
recording and proposed metadata before applying changes.

## Pick tracks

Use **Browse untagged** without entering a search. By default it includes tracks
missing artist, title, or album in the indexed library, plus tracks whose linked
recording has no MusicBrainz ID. You can filter either condition separately.
The missing-fields filter describes the indexed Serato metadata; scanning reads
the actual embedded tags for the review comparison.

Browse one page at a time or use **Search** to find a specific artist, title, album, or
filename. Selections stay selected when you change pages or searches. Selecting
a page selects only its displayed tracks. **Scan selected (N)** starts the audio
lookup for those tracks; opening the browser does not start a scan.

Each file shows its Serato membership and availability. **Import pending** and
**Membership unverified** entries remain inspectable, but only verified active,
available files can be selected for processing. Missing files, offline volumes,
access failures, and unknown availability have distinct labels. A page selection
includes only processable files. Removed entries are available in Library's
**Removed from Serato** filter, with their last normal path and **Show History**.

## Review in List or Focus

**List** lets you compare several tracks. **Focus** shows one track at a time,
with Previous and Next navigation. Both modes share the same choices and
approvals. The app remembers the display mode.

The **Current** values come from the file's embedded tags read during scanning.
**Proposed** values come from the selected MusicBrainz recording and release.
Choose which fields to change. For titles, Keep current preserves your title,
Use suggestion uses the MusicBrainz title, and Merge is available when the app
can preserve supported version information. Check the resulting title before
approving. Unchanged fields remain available in their disclosure.

An approval stages that track for Apply. Editing the proposal clears its approval
so you can review the new result. In Focus, **Approve & Next** advances to the
next unapproved ready match. It never writes tags automatically.

## Understand the match

The audio match score is the AcoustID fingerprint score. It is not a probability
that all the proposed tags are correct. Several recording IDs can share one
fingerprint result and therefore the same score.

The app separately explains whether the recording is ambiguous or the audio
score is low. Its existing conservative rule treats recording IDs from results
scoring at least 90%, or within five percentage points of the leading result,
as plausible competitors. A single plausible recording does not establish the
correct album, release year, or remix label.

**Choose recording** lists the recording IDs returned for your audio lookup,
including lower-scoring alternatives. Details load a page at a time. A failed
detail request remains visible and can be retried. This is not a search of the
entire MusicBrainz database.

### Artist/title matches

When AcoustID answers but returns no recordings, a common case for DJ edits
and rare releases, Auto-Tag searches MusicBrainz for the file's embedded
artist and title. Both tags must be present; it never guesses from the
filename. Version labels such as `(Intro)` or `- Radio Edit` are left out of the
search and only used to rank the results, so the base recording can still be
suggested for an edit. A failed AcoustID lookup stays a failure and does not
start a search.

These rows show **Text match: N%** with a note that the row was found by
artist/title search. The percentage measures how closely the text agrees;
nothing confirms the audio. They are always weak suggestions. **Approve all
suggested matches** and **Approve all ready matches** skip them, so each one
must be approved on its own. **Choose recording** lists the other search
results. The title choice (**Keep current**, **Merge**, **Use suggestion**)
still decides whether your version label survives. Applying one stores the
recording link without an AcoustID identifier.

Choosing another recording replaces the proposal and resets its field/release
choices and approval. If its metadata cannot be loaded, the existing proposal
stays intact. **Choose release** instead picks an album or edition of the current
recording. These are different decisions.

## Continue work and apply

You can navigate to other screens while scanning. Returning to Auto-Tag restores
the search, selected tracks, progress, proposals, edits, approvals and focus.
**Stop scan** cancels outstanding lookups while keeping completed results.
**New Scan** explicitly resets the session. The review session lasts for the
running app; it is not restored after quitting and relaunching.

**Apply approved tracks (N)** applies the approved proposals through the normal
operation engine. It checks whether files changed since review. Serato library
and tag writes queue while Serato is running; the queue is stored in the library
database, so quitting crate-agent before Serato does not lose them. If an external write fails after
the library transaction committed, the UI retains the recovery information;
reapplying the same batch is not a substitute for recovery.

Removing a track from Serato retires its indexed entry, preserving its recording
link and History. Serato can remove membership alone or also move audio to Trash.
crate-agent retirement itself never moves, deletes, or restores audio.
Restoring a file from Trash does not import it into Serato. Re-adding verified
audio in Serato can reactivate the retained entry; an old Auto-Tag result does not
gain permission to write after retirement or content replacement. Start a new
scan for that file. Unavailable review errors include the filename.

Use **Re-scan File Info** in Library to check Serato's complete saved library.
The scan stays idle at startup and does not restart when Serato closes. Auto-Tag
remains blocked until a scan succeeds. A missing, unreadable, or corrupt Serato
database leaves processing blocked and shows **Retry Sync**; it never means the library is empty. Missing
audio that Serato still references remains a member. The **Missing** Library
filter includes all active unavailable entries, with offline and permission
problems labeled accurately. External volumes must be online for retirement
decisions; independent external Serato libraries and portable path translation
are outside the supported scope. See the
[saved-library reconciliation contract](serato-membership-reconciliation.md).

## Comfortable or Compact

The app-wide density control adjusts spacing throughout the app. Comfortable is
the default; Compact fits more rows. This preference is shared with General
settings and does not change selections or metadata decisions.

## Shared list controls

Browse and Search support artist, title, album, and path matching, with Previous
and Next page controls. Select page is reversible; Clear selection also clears
hidden pages and searches. Review List search leaves approvals intact and reports
hidden approvals. Bulk approval actions apply across the entire scan. See the
[shared list-control contract](list-controls.md).
