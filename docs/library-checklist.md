# Library checklist

Every file in **Library** shows what it still needs before the library is
finished. The **Still needs** column lists those items as short tags, the chips
above the table filter by them, and the genre, BPM and key filters narrow the
list further. All of them combine with the search and the library status.

## Items

A file passes an item, fails it, or the item is *unknown* because crate-agent
hasn't read the fact yet.

| Tag | Fails when | Unknown when | Fix |
| --- | --- | --- | --- |
| Crate | The file is in no Serato crate (`Subcrates/*.crate`). SmartCrates don't count. | Serato's crates haven't been read yet. | Add it to a crate in Serato. |
| Cues | The file's `Serato Markers2` tag has no cue points. | Its Serato data hasn't been read, or couldn't be: an unsupported format, a malformed tag or an unreadable file. Workers lists the reason. | Set cue points in Serato. |
| Grid | Serato's database says the beatgrid isn't locked. The tooltip says **No beatgrid** when the file has no beatgrid markers at all. | Serato's database has no lock flag for the file. | Lock the beatgrid in Serato. |
| Tags | Artist, title, genre, BPM or key is empty. | Never. | Artist and title through Auto-Tag, genre in your tag editor, BPM and key with Analyze in Serato. |
| Quality | A lossy file below 256 kbps (`LibraryChecklist.minimumLossyBitrateKbps`). A lossless file (FLAC, WAV, AIFF) passes. | A lossy file's bitrate isn't known. | Replace it with a better copy. |
| Versions | The file's song family has more than 4 versions (`LibraryChecklist.maximumFamilyVersions`) and the file isn't the main version or another encoding of it. Files outside a family always pass. | Never. | Remove filler, or mark the file as a keeper. |
| Duplicate | The file is in a confirmed duplicate group, found from cached digests. Needs-listening groups don't count. | Never. | Remove the extra copy, or mark the file as a keeper. |

## Unknown versus failing

An unknown item is never shown as a failure. It reads as, for example,
**Cues unknown** in secondary text, and the definite-failure chips (**No cues**,
**Grid unchecked**, **Not in a crate**, **Low quality**) leave it out. An
unknown item still keeps the file from being Finished, so it counts toward
**Needs work**. After an upgrade, every row starts with unknown items and fills
in as the background reads finish; browsing never waits for them.

The tooltip on **Still needs** gives one sentence per item, naming its fix or
why it's unknown. If a row's stored checklist has a bit no item names, the cell
reads **Checklist unreadable** in red, with the reason in its tooltip; it never
guesses.

A family's main row shows its own checklist, without the Versions item, and adds
**N of M files need work** for the family's files in the current library
status. The checklist is per file: quality, duplicates, cues and grid belong to
each file, not to the recording.

**Date added** is Serato's date added when its database has one, and otherwise
the time crate-agent first indexed the file; the tooltip says which. **My
plays** is the play count from the last Serato History read; once History has
been read, a file with no play has 0. Until History has been read for the
first time, which crate-agent records in a persisted stamp (source `history`
in `checklist_source_stamps`) written with the counts, every file's plays read
**unknown**. A missing value reads **unknown**, and sorts last in both
directions. Files removed from Serato have no checklist, so these columns are
empty for them.

## Keepers

Right-click a row and choose **Mark as Keeper** to protect it, or **Clear
Keeper** to remove the protection.

- A keeper is recording-level. Every file that shares its recording key (its
  MusicBrainz recording ID, else its `tracks` row, else the file itself) is
  protected too, so the FLAC and MP3 of one Auto-Tagged song are kept together.
- A protected file is **Finished**, shows **Keeper**, and its Versions item is
  suppressed. Its other tags (Crate, Cues, Grid, Tags, Quality) still show.
- Only the file's own mark suppresses **Duplicate**. Another encoding that is
  protected through the shared recording still shows Duplicate, so the worse
  copy stays removable.
- Protection follows each file's current recording key. Applying an Auto-Tag
  match that gives a file the kept recording's MusicBrainz ID protects it too,
  and undoing that match takes the protection away again. Neither writes a
  keeper event of its own: the match event in History is the record.
- **Clear Keeper** clears every mark on the recording. Undoing a clear restores
  them all, unless a newer keeper already protects the recording; then the undo
  is refused as changed since it was shown, so a recording never ends up with
  a keeper it didn't have.
- Marking and clearing are `OperationEngine` mutations with History entries;
  undo them from History. They change only crate-agent's database, never Serato
  files, so they work while Serato is running.
- Replacing a file's content, or removing the file from the library, drops
  its mark. Undoing a removal doesn't bring the mark back: the file's
  retirement invalidated it, so mark the file again if it should stay a keeper.

## Removing several files

Select files in the Library and choose **Move N to Trash…**. The review names
the files, how much space they free and what happens: each file leaves
Serato's library and every crate, is moved to the Trash and has its row
retired, through the same staged removal Library Cleanup uses
(`LibraryBatchRemoval`, one `OperationEngine.removeFile` per file under one
History batch, so one undo restores them all while they are in the Trash).
The command is offered in the Active view only, counts the selected files the
current search and filters show, and takes at most 500 at once. It refuses the
whole selection, naming the files, when one changed after it was selected, is
not active and on disk, or is already being removed. A file that fails is
reported and stays selected; the removed rows leave the selection. While Serato
is running the button is disabled and a banner says why.

## Chips

The chips are **Needs work**, **Not in a crate**, **No cues**, **Grid
unchecked**, **Low quality**, **Never played**, **Too many versions** and
**Finished**. One chip can be chosen at a time; press it again to clear it.

- Each count is the number of *files* in the current library status, search and
  genre, BPM and key filters that the chip matches, ignoring the chosen chip.
  Counts read **…** while they load, after the first page.
- **Not in a crate**, **Grid unchecked** and **Never played** each come from one
  Serato source: Subcrates, `database V2` and History. Until crate-agent has
  read that source once, the chip's count reads **unknown**, never 0.
- **Never played** is disabled until Serato History has been read for the
  first time, because play counts are only read while Serato is closed. Until
  then it matches nothing. Once the History stamp exists it stays available
  across later refreshes, Serato reopening and relaunches. While it is
  disabled, its tooltip and a note beside the chips give the reason, including
  why the last read failed.
- Like a search, a chip shows a family's main row when any of its files
  matches, and lists the matching files beneath it.

## Genre, BPM and key filters

- **Genre** is a multi-select. Spellings that differ only in case, width or
  spaces ("House", "house ") are one option, shown as the commonest spelling.
- **BPM from** and **BPM to** form an inclusive range; press Return to apply.
  Either end may be left empty, and two empty ends (or a lower end of 0 with no
  upper end) apply no range. Negative, non-numeric and reversed ranges are
  refused with a message. Files with no BPM, or a BPM of 0, never match.
- **Key** matches the chosen key, one step either way on the Camelot wheel, and
  its relative major or minor. Musical, Camelot and Open Key notations are all
  read. A key no notation reads never matches.
- The genre and key menus list what the current library status contains, and
  the genre counts cover the whole status scope, before search, chips and the
  other filters.
- **Clear filters** clears the genre, BPM and key filters.

## Where the facts come from

Nothing in the checklist writes Serato files. The facts are cached in
crate-agent's database by background services, and the checklist is computed in
SQL from them each time the Library loads.

| Fact | Source | Refreshed |
| --- | --- | --- |
| Crate membership | `Subcrates/*.crate`, by `SeratoLibraryFactsService` | After each sync, while Serato is closed, when the crate files change |
| Beatgrid lock, date added | `database V2` (`bbgl`, `uadd`/`tadd`), by `SeratoLibraryFactsService` | Same as crates |
| Cue points, beatgrid markers | The audio file's Serato tags, by `SeratoAnalysisWorker` | In the background, once per file content |
| Duplicates | Cached digests, by `ChecklistDuplicateRefresher` | When duplicate evidence changes, at most every 30 seconds |
| Play counts | Serato History, by `SeratoPlayCountService` | After each sync, while Serato is closed |
| Popularity, Hot | ListenBrainz and Deezer, by `PopularityService` | After each sync and every 6 hours, stalest recordings first, once a source is on |
| Artist, title, genre, BPM, key, bitrate | The indexed `files` columns | With every sync |

## Prepare

**Prepare** works through the unfinished tracks one at a time, most promising
first. It runs the Library query with the **Needs work** chip, the same search,
chips and genre, BPM and key filters, and one fixed order: the rank in
`PrepareRanking`, which is the track's Popularity plus its Hot plus ten points
for each of your own plays. A track with none of the three signals has no rank
and comes last, so until a source is on, your plays decide the order.

Each card shows the track, what it still needs with the fix for each item, and
its signals, and offers the fixes:

- **Play**, through the app-wide player.
- **Fix tags** selects the track in Auto-Tag and opens it; if a scan is in
  progress the card says so instead.
- **Open in Serato** opens the file in Serato DJ, for cue points and the
  beatgrid; it is disabled when Serato DJ isn't installed.
- **Mark as Keeper** and **Clear Keeper**, as in the Library.
- **Show other versions** opens the Library on the track's family.
- **Move to Trash** asks first, saying how much space it frees, then runs the
  same undoable removal the Library Cleanup uses. It is disabled while Serato
  is running.

Adding to a crate is not offered yet. **Previous** and **Next** move through
the list; a track that becomes Finished leaves it on the next refresh.

## Popularity and Hot

Two sortable columns say how well known a recording is and whether it is rising.
Both start **off**: no lookup runs and the cells read "off" until a source is
switched on, in Settings → Popularity or in the sheet the Library offers the
first time either column is sorted. Only the artist, title, ISRC and MusicBrainz
recording ID ever leave the machine. A recording no source answered shows
"unknown", never 0, and sorts last in both directions.

- **ListenBrainz** receives MusicBrainz recording IDs and returns total listens.
- **Deezer** receives the ISRC, or the artist and title when there is none, and
  returns the track's rank. A search hit whose artist is not the file's artist is
  discarded.

**Popularity** is the mean of each source's figure normalized to 0 to 100: ten
million ListenBrainz listens or a Deezer rank of one million both score 100.
**Hot** is the percentage growth between a recording's latest figure and an
earlier one at least seven days older within the last four weeks, averaged
across sources, so it needs two lookups of the same recording. Until then the
Deezer chart fills it, at most once a week: the top track scores 100 and the
hundredth scores 1, for every encoding of a matching recording. A computed
growth always replaces the chart figure, a recording that leaves the chart
loses it, and a growth whose earlier lookup ages out of the four weeks reads
"unknown" again.

Scores attach to the recording key the keeper uses (the MusicBrainz recording ID,
else the track, else the file), so every encoding of a recording shares them.
`PopularityStore` is the only writer of `popularity_lookups` (each source's raw
figure over time) and `popularity_scores` (the derived columns the Library
joins). A pass looks up at most 500 recordings in batches of 50, one request per
second per source. A failed answer for one request skips that recording until
its next weekly turn; being offline, rate limited (Deezer's quota envelope
included) or interrupted ends the pass and keeps what landed, and a pass that
starts during a library sync waits for it. The Workers window's Popularity card
shows the pass and offers **Refresh now**.

**Workers** shows each service's status: the Serato crates and beatgrid locks
card, the cue-point card with read, pending, failed and unsupported counts and
the files that couldn't be read, and the duplicate checklist card. A failure in
any of them is shown in red with its reason.

The query contract, its CTE order and the budgets are in
`LibraryChecklist.swift` and the
[library readiness plan](superpowers/plans/2026-10-18-library-readiness-checklist.md).
