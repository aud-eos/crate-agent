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
   or unclaimed. Unclaimed means no other file is linked to it and it has no
   AcoustID, MusicBrainz, or ISRC identifier. Anything else is refused with
   `fingerprintCollision`, naming the other file when there is one. A 120-second
   fingerprint can match two different recordings (Clean and Dirty edits), and
   grouping must not merge them or hand one the other's MusicBrainz identity.
2. **Each grouping link is its own per-file event**
   (`song_family_recording_linked`, with `file_id` set). It shows in the file's
   History, and undo applies the retired and replaced-file guard to it.
3. **Undo removes a grouping link only while grouping still owns it.** That is,
   while the file is still linked to that recording and the recording is still
   unclaimed. Once a later match claims it, undo keeps the link (the match owns
   it now) and still undoes the membership. Redo re-creates a link only under
   rule 1.
4. **Live members.** A member counts only while at least one non-retired file is
   linked to it. A member whose last file is retired, replaced, or re-matched to
   another recording keeps its assignment silently, so undoing that change
   brings it back. Members without files never count toward the version count,
   the two-member minimum, or the displayed representative. A change that
   dissolves a family clears them too.
5. **Membership never moves silently.** Adding a recording that is already in
   the family is a no-op. A live recording in another family is refused with
   `memberAlreadyInFamily`, and the client offers `merge` instead.

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

## History and undo

Every call is one History batch. The membership change is one `.songFamily`
event that records the affected families and recording assignments before and
after. Each link it needed is a separate per-file event. Undo restores the
earlier membership only if the recorded later state is still current;
otherwise it fails with `changedSinceRecorded`, and the later change must be
undone first. Links are undone under rule 3. A recording row that grouping
created is left in place, as MusicBrainz undo does. Grouping and its undo both
wait for library synchronization to be ready, like other library changes.
