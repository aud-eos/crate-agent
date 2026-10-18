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
  separate recordings, but recordings that share a MusicBrainz recording ID
  are one version (`SongFamilyMutation.versionKeySQL`), and `family(id:)`
  lists them together. Unmatched recordings are each their own version.
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
   History, and records the file's membership revision. Its undo checks the
   link itself (rule 3) instead of the general retired and replaced-file guard.
   Its redo takes that general guard.
3. **Undo removes a grouping link only while grouping still owns it.** That is,
   while the file is still linked to that recording and the recording is still
   unclaimed. Once a later match claims it, undo keeps the link (the match owns
   it now) and still undoes the membership. A retired file also keeps its link,
   as retirement keeps every file's link, so undoing a group never waits for a
   file to return. Redo re-creates a link only while the file is in the library
   at the revision undo recorded, so a file retired or replaced since is
   refused, and only under rule 1: the file's current fingerprint must still
   identify that recording, and the recording must still be unclaimed.
4. **Live members.** A member counts only while at least one non-retired file is
   linked to it. A member whose last file is retired, replaced, or re-matched to
   another recording keeps its assignment silently, so undoing that change
   brings it back. Members without files never count toward the version count,
   the two-version minimum, or the displayed representative. A change that
   dissolves a family clears them too. Every minimum counts versions, not
   recordings: `create` and `split` need two versions, and a family with
   fewer than two live versions is dissolved as far as the user can tell: `family(id:)` returns nil
   and Library offers no family commands for it, while its assignments wait for
   files to return. `attach`, `merge`, `split` and `setRepresentative` refuse
   such a family with `familyNoLongerShown` instead of reviving it.
5. **Membership never moves silently.** Adding a recording that is already in
   the family is a no-op. A recording in another family with two or more live
   members is refused with `memberAlreadyInFamily`, which names that family's
   other versions, and the client offers `merge` instead. A recording whose family has
   fewer than two live members is taken over: the change dissolves that family
   in the same journaled event, so undo restores it. Liveness is measured before
   the change's own grouping links, so linking a file back to its recording
   doesn't revive the family the user is regrouping it out of.

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
| `apply(_:authority:)` | Runs several creates, attaches and merges as one batch; one refusal refuses them all. |
| `family(id:)`, `family(containingTrack:)` | Reads a family's live members, with its displayed representative. |

Members are passed as `SongFamilyMember.track(id)` or `.file(id)`. In the same
batch as the change, the service links each unlinked `.file` under rule 1, so
a refused link leaves nothing behind. Retired files are rejected with
`fileRetired`, files without a current fingerprint with `recordingUnidentified`,
and recordings with no file in the library with `recordingHasNoFiles`.

## Displayed representative

`SongFamilyRepresentative` chooses the member shown for a family. Members with
an active, available file are preferred. Among those, the saved choice wins.
Otherwise members are ranked in tiers:

1. a title marked Main, Original or Album Version (`(Original Mix)`,
   `[Main Version]`, `(Album Version)`), unless the same annotation names
   another version (`(Original Instrumental)`, `(Main Dub)`);
2. a bare title, with no version annotation. A featured-artist credit
   (`(feat. Wizkid)`, `(with Drake)`), a remaster note (`- 2011 Remaster`) or a
   bare year doesn't count as one;
3. a Dirty or Explicit edit with no other qualifier (`(Dirty)`, `[Explicit]`);
4. anything else.

Within a tier a MusicBrainz-matched recording comes first, then the lowest
recording id. A retired or missing saved choice is passed over without being
replaced, and returns when it is available again.

## Library

- **Main row.** A family with at least two live versions shows one main row in
  each status view that holds its files: the displayed representative's file.
  A family with fewer than two live versions, and any file whose recording has
  no live file, shows as standalone rows with no family commands, in every
  view, including **Removed from Serato**.
  - **Versions** counts the family's different live recordings, the same count
    as `SongFamilyService.family(id:)`, as in **5 versions**, or
    **5 versions · 2 selected** when members are selected.
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
    alternates). A selected file that changed after it was selected refuses
    the command, naming the file, instead of being left out.
  - Each targeted file is passed to `SongFamilyService` as authority
    (`applyBatch(authorizingMembershipTokens:)`), so a file whose membership
    changes before the transaction refuses the whole change, naming the file
    (`SongFamilyError.changedSinceShown`).
  - Commands read a targeted file's family the way Library shows it
    (`SongFamilyService.memberships(ofFiles:)`): a file in a family with
    fewer than two live versions counts as standalone. **Merge** never pulls
    such a hidden family in, and **Add** takes its recording over (rule 5).
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

## Find Versions

**Find Versions…** in Library's header suggests families across the library.
`SongFamilySuggester` is the API: `suggestions()` scans, and `apply(_:)` groups
the confirmed suggestions through `SongFamilyService`, so every family follows
the rules above and a collision is refused by name.

- **Candidates.** Processable files with the same normalized artist and title
  stem. The stem drops every annotation that names a version in the
  `VersionLabel` vocabulary, labelled or not (`(Clean)`, `- Radio Edit`,
  `(DJ Snake Remix)`, `(Club Mix)`), and every featured-artist annotation.
  Both sides drop a trailing featured credit (`feat.`, `ft.`, `featuring`; for
  the artist also `&`), punctuation, case and diacritics. Words in the base title
  are kept, so "Dirty Diana" is not "Diana".
- **Recordings.** Each candidate is placed on the recording grouping would link
  it to. Linked files keep their recording; an unlinked file takes the
  recording its current fingerprint names. Files without a current fingerprint
  are left out and counted until fingerprinting finishes.
- **Same audio.** Files that are duplicates, not versions, are left out and
  listed with a pointer to **Duplicates**: recordings whose files share a
  decoded-audio or byte digest in the duplicate digest cache (no new decode),
  unlinked files that share a fingerprint or whose fingerprint another file
  already claims (grouping would refuse them), and recordings whose own files
  name different labels.
- **Targets.** A suggestion with no member in a live family creates one. One
  with members in one live family adds the others to it; one whose members are
  all grouped already is not shown. One spanning several live families merges
  them into the family holding most of its files, then adds the rest.
- **Confidence.** A suggestion is **Strong** (pre-checked) when every version
  names a different set of labels, and **Near** (unchecked) when versions repeat
  a set or the suggestion merges families. Recordings that share a MusicBrainz
  recording are one version, as everywhere else. A shared MusicBrainz work is
  meant to be the strongest signal, but crate-agent does not record work IDs
  yet (#262).
- **Checklist.** One row per suggested family, showing each file's title,
  version label and length. The family checkbox is mixed while only some
  versions are checked; unchecking a version leaves it out. A new family needs
  two checked versions. A rescan keeps the user's checks.
- **Apply.** The checked families are one History batch, undone in one step.
  One apply groups at most `SongFamilySuggester.maximumFamiliesPerApply` (100)
  families, so the writer is held well under 500 ms; group again for the rest.

`LibraryPagingTests` measures the 30,000-file fixture with 2,000 three-version
suggestions. The scan reads the library on a database reader, off the main
actor, so Library stays responsive while it runs. Budgets: scan under 2 s, main
actor stalls under 100 ms, and an apply's longest writer wait under 500 ms.

## History and undo

Every call is one History batch. The membership change is one `.songFamily`
event that records the affected families and recording assignments before and
after. Each link it needed is a separate per-file event. Undo restores the
earlier membership only if the recorded later state is still current;
otherwise it fails with `changedSinceRecorded`, and the later change must be
undone first. Links are undone under rule 3. A recording row that grouping
created is left in place, as MusicBrainz undo does. Grouping and its undo both
wait for library synchronization to be ready, like other library changes.
