# Song families

A song family groups alternate recordings of one song (Main, Intro/Outro, Clean,
Instrumental, Acapella, remixes) so Library can show one row per song. It is the
user-curated `works` layer from Pillar C in the design plan, not a claim that
every member belongs to one MusicBrainz release.

## Model

- `works` holds one row per family. Its `representative_track_id` is the
  user's saved main-version choice, or null to use the automatic choice.
- A member is a recording (`tracks` row), linked by `tracks.work_id`. A
  recording belongs to at most one family. Several files that encode the same
  recording (FLAC and MP3) count as one version.
- Members keep their own fingerprint identity, tags, and MusicBrainz IDs.
  Grouping never writes audio tags, Serato files, or recording identifiers.
- A family always has at least two recordings. A change that leaves fewer
  dissolves it and leaves the remaining recording standalone.

## API

`SongFamilyService` is the contract every client uses:

| Call | Effect |
| --- | --- |
| `create(_:representative:)` | Groups two or more recordings. |
| `attach(_:to:)` | Adds recordings to a family. |
| `detach(_:from:)` | Removes recordings; dissolves the family below two. |
| `merge(_:into:)` | Moves every member of the given families into one, keeping its saved main version. |
| `split(_:from:)` | Moves two or more members into a new family, with the saved main version if it moves. |
| `setRepresentative(_:of:)` | Saves a main version, or clears it with nil. |
| `family(id:)`, `family(containingTrack:)` | Reads a family with its displayed representative and members. |

Members are passed as `SongFamilyMember.track(id)` or `.file(id)`. A file
without a linked recording resolves to the `tracks` row its current Chromaprint
fingerprint identifies, created when missing. Retired files and files without a
current fingerprint are rejected with `recordingUnidentified`, so unmatched
files can be grouped without MusicBrainz data.

A recording that already belongs to another family is never reassigned:
`create` and `attach` throw `memberAlreadyInFamily`, and the client offers
`merge` instead.

## Displayed representative

`SongFamilyRepresentative` chooses the member shown for a family. Members with
an active, available file are preferred. Among those, the saved choice wins,
then a title marked Main or Original (`(Original Mix)`, `[Main Version]`), then
a MusicBrainz-matched recording without a version annotation, any
MusicBrainz-matched recording, any unannotated title, and finally the lowest
recording id. A retired or missing saved choice is passed over without being
replaced, and returns when it is available again.

## History and undo

Every call is one `OperationEngine` mutation (`.songFamily`) in its own batch.
Its event records the affected families, recording assignments, and file links
before and after the change. Undo restores the earlier state only if the
recorded later state is still current; otherwise it fails with
`changedSinceRecorded`, and the later change must be undone first. Undo leaves
a recording row it created in place but unlinks its file, as MusicBrainz undo
does.
