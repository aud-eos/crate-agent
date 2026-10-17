# Song families

A song family groups alternate recordings of one song (Main, Intro/Outro, Clean,
Instrumental, Acapella, remixes) so Library can show one row per song. It is the
user-curated `works` layer from Pillar C in the design plan, not a claim that
every member belongs to one MusicBrainz release.

## Model

- `works` holds one row per family. Its `representative_track_id` is the
  user's saved main-version choice, or null to use the automatic choice.
- A member is a recording (`tracks` row), linked by `tracks.work_id`. A
  recording belongs to at most one family. Files reach a family through
  `files.track_id`, so files linked to the same recording row count as one
  version. Encodings whose fingerprints differ (most FLAC and MP3 pairs) are
  separate recordings, and count as separate versions.
- Members keep their own fingerprint identity, tags, and MusicBrainz IDs.
  Grouping never writes audio tags, Serato files, or recording identifiers.

## The link and membership rule

Every path that changes `files.track_id` or `tracks.work_id` follows these
rules:

1. **Identity paths own links.** MusicBrainz match and undo, and file identity
   observation, decide which recording a file is. Grouping only fills a gap:
   it links a non-retired, unlinked file with a current fingerprint to the
   recording that fingerprint identifies, and only when that recording is new
   or unclaimed. Unclaimed means no other non-retired file is linked to it and it has no
   AcoustID, MusicBrainz, or ISRC identifier. Anything else is refused with
   `fingerprintCollision`, naming the other file when there is one. A 120-second
   fingerprint can match two different recordings (Clean and Dirty edits), and
   grouping must not merge them or hand one the other's MusicBrainz identity.
   Such files share an audio fingerprint, so crate-agent treats them as one
   recording, and they cannot yet be grouped as separate versions.
2. **Each grouping link is its own per-file event**
   (`song_family_recording_linked`, with `file_id` set). It shows in the file's
   History. Its undo and redo check the link itself (rule 3) instead of the
   general retired and replaced-file guard.
3. **Undo removes a grouping link only while grouping still owns it.** That is,
   while the file is still linked to that recording and the recording is still
   unclaimed. Once a later match claims it, undo keeps the link (the match owns
   it now) and still undoes the membership. A retired file also keeps its link,
   as retirement keeps every file's link, so undoing a group never waits for a
   file to return. Redo re-creates a link only under rule 1.
4. **Live members.** A member counts only while at least one non-retired file is
   linked to it. A member whose last file is retired, replaced, or re-matched to
   another recording keeps its assignment silently, so undoing that change
   brings it back. Members without files never count toward the version count,
   the two-member minimum, or the displayed representative. A change that
   dissolves a family clears them too. A family with fewer than two live
   members is dissolved as far as the user can tell: `family(id:)` returns nil
   and Library offers no family commands for it, while its assignments wait for
   files to return.
5. **Membership never moves silently.** Adding a recording that is already in
   the family is a no-op. A recording in another family with two or more live
   members is refused with `memberAlreadyInFamily`, which names that family's
   versions, and the client offers `merge` instead. A recording whose family has
   fewer than two live members is taken over: the change dissolves that family
   in the same journaled event, so undo restores it.

Refusals name files and recordings by title, or by file name when a file has
no title.

## API

`SongFamilyService` is the contract every client uses:

| Call | Effect |
| --- | --- |
| `create(_:representative:)` | Groups two or more recordings. |
| `attach(_:to:)` | Adds recordings to a family; existing members are left as they are. |
| `detach(_:from:)` | Removes recordings; dissolves the family below two live members. |
| `merge(_:into:)` | Moves every member of the given families into one, keeping its saved main version. |
| `split(_:from:)` | Moves two or more members into a new family, with the saved main version if it moves. |
| `setRepresentative(_:of:)` | Saves a main version, or clears it with nil. |
| `family(id:)`, `family(containingTrack:)` | Reads a family's live members, with its displayed representative. |

Members are passed as `SongFamilyMember.track(id)` or `.file(id)`. In the same
batch as the change, the service links each unlinked `.file` under rule 1, so
a refused link leaves nothing behind. Retired files are rejected with
`fileRetired`, files without a current fingerprint with `recordingUnidentified`,
and recordings with no file in the library with `recordingHasNoFiles`.

## Displayed representative

`SongFamilyRepresentative` chooses the member shown for a family. Members with
an active, available file are preferred. Among those, the saved choice wins,
then a title marked Main or Original (`(Original Mix)`, `[Main Version]`), then
a MusicBrainz-matched recording without a version annotation, any
MusicBrainz-matched recording, any unannotated title, and finally the lowest
recording id. A retired or missing saved choice is passed over without being
replaced, and returns when it is available again.

## Library

- **Main row.** A family with at least two versions in the current status scope
  shows one main row: the displayed representative's file.
  - **Versions** counts the family's different recordings, as in **5 versions**,
    or **5 versions · 2 selected** when members are selected.
  - The files beneath the main row also include other encodings of the main
    version, so the disclosure counts files instead: **Show 4 files** /
    **Hide 4 files**.
  - Families sort by the main row's values, and their files stay directly
    beneath it.
- **Disclosure.** It changes only what is shown. Use the button, the context
  menu, or Right and Left Arrow on the focused row.
  - Left Arrow on a file beneath a main row collapses the family and focuses the
    main row.
  - Arrow keys that would change nothing keep their usual meaning.
  - Selecting a main row never expands it, and collapsing keeps every selection.
- **Search.** A search matches every member, and a family appears when any
  member matches.
  - While searching, the matching files are always shown beneath their main
    row, and the button reads **2 matching files shown** and is disabled.
  - Clearing the search returns to the saved disclosure. Nothing is selected
    automatically.
- **Select all and Include alternates.**
  - **Select all** selects main and standalone rows.
  - With **Include alternates** checked beside it, Select all also selects each
    in-scope family's processable alternate files.
  - Each main row's **Include alternates** checkbox selects or deselects that
    family's processable alternates without expanding it. It is mixed when only
    some are selected. The context menu offers the same command as **Select
    Alternate Files** / **Deselect Alternate Files**.
  - Turning Select all off clears every in-scope file, including alternates it
    or a family checkbox added.
  - Unavailable alternates remain visible and selectable by hand, but these
    controls never select them.
- **Context menu commands.** The menu offers grouping the targeted files,
  adding them to the clicked family, merging their families into it, splitting
  them into a new family, setting or clearing the main version, and removing
  them from the family. Each is one History entry.
  - A command acts on the clicked row alone unless that row is selected. Then it
    acts on the selection, limited to files the view shows (including collapsed
    alternates) at the revision they were selected at.
  - Each targeted file is passed to `SongFamilyService` as authority, so a file
    whose membership changes before the transaction refuses the whole change.
  - `LibraryFamilyActions` and `LibraryBrowserModel.familyActionTarget(for:)`
    are the API the view calls.
- **Empty libraries.** The family columns and the global Include alternates
  toggle appear only when a family is in view.

The projection runs in SQL (`LibraryBrowseQuery`). Family files are ranked in
small CTEs using the same `SongFamilyRepresentative` ordering as the service,
and the outer pass over `files` joins only their results. Each snapshot reads a
family's members at most once.

`LibraryPagingTests` holds the 30,000-file paging fixture, with 6,000 files in
2,000 families, to the 500 ms interaction budget and attaches the timings. Each
step is under that budget:

- count;
- first and distant pages;
- the select-all scope;
- expand and collapse;
- the Include alternates toggle.

Each interaction includes the new snapshot, its first page, its families'
members, and the selection summary.

## History and undo

Every call is one History batch. The membership change is one `.songFamily`
event that records the affected families and recording assignments before and
after. Each link it needed is a separate per-file event. Undo restores the
earlier membership only if the recorded later state is still current;
otherwise it fails with `changedSinceRecorded`, and the later change must be
undone first. Links are undone under rule 3. A recording row that grouping
created is left in place, as MusicBrainz undo does. Grouping and its undo both
wait for library synchronization to be ready, like other library changes.
