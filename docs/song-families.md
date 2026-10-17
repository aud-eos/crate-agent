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
   files to return.
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
   `[Main Version]`, `(Album Version)`);
2. a bare title, with no version annotation;
3. a Dirty or Explicit edit with no other qualifier (`(Dirty)`, `[Explicit]`);
4. anything else.

Within a tier a MusicBrainz-matched recording comes first, then the lowest
recording id. A retired or missing saved choice is passed over without being
replaced, and returns when it is available again.

## History and undo

Every call is one History batch. The membership change is one `.songFamily`
event that records the affected families and recording assignments before and
after. Each link it needed is a separate per-file event. Undo restores the
earlier membership only if the recorded later state is still current;
otherwise it fails with `changedSinceRecorded`, and the later change must be
undone first. Links are undone under rule 3. A recording row that grouping
created is left in place, as MusicBrainz undo does. Grouping and its undo both
wait for library synchronization to be ready, like other library changes.
