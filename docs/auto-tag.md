# Reviewing Auto-Tag suggestions

Auto-Tag looks up the audio of tracks you select, then lets you review the
recording and proposed metadata before applying changes.

## Pick tracks

Use **Browse untagged** without entering a search. By default it includes tracks
missing artist, title, or album in the indexed library, plus tracks whose linked
recording has no MusicBrainz ID. You can filter either condition separately.
The missing-fields filter describes the indexed Serato metadata; scanning reads
the actual embedded tags for the review comparison.

Browse one page at a time or use **Search** to find a specific artist, title, or
filename. Selections stay selected when you change pages or searches. Selecting
a page selects only its displayed tracks. **Scan selected (N)** starts the audio
lookup for those tracks; opening the browser does not start a scan.

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
and tag writes queue while Serato is running. If an external write fails after
the library transaction committed, the UI retains the recovery information;
reapplying the same batch is not a substitute for recovery.

## Comfortable or Compact

The app-wide density control adjusts spacing throughout the app. Comfortable is
the default; Compact fits more rows. This preference is shared with General
settings and does not change selections or metadata decisions.
