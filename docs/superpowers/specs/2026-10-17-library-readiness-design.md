# Library readiness: search, sort and filter toward a finished library

Issues: #43 (sort by recently added), #51 (advanced search, sorting and filtering), #137 (structured version attributes and filtering). Related: #34 (Serato History play counts), #136 (song families), #203/#204 (duplicates), #250 (USB export, future).

## Intent

The owner has a library of more than 30,000 tracks. At that size, browsing doesn't help either when preparing playlists or when playing on the fly without one. The goal isn't a target size or track count. It's a **finished library**: every track is in a playlist, organized, prepared, a great song, and a good-quality file. A library like that makes DJing easier and gives better results.

Search, sort and filter serve two jobs at once:

- **Bring the good stuff up.** Live, with no plan, the owner looks for ideas the crowd will love: an artist's best or hottest tracks, or the strongest tracks across a mix of artists.
- **Push the noise down, then remove it.** Filler is *mostly* less popular tracks, plus too many versions of one song and duplicates. Obscure tracks can still get great reactions, so popularity alone never condemns a track. A large part of the workflow is deleting tracks to save space, cut noise, and make the library easier to carry (#250).

Today the owner searches by genre, BPM range, compatible key, sometimes clean versions only, and often by artist. Some artists have many tracks, and some of those are filler, so a ranking *within an artist* matters.

## Goals

1. **A per-track "still needs" checklist** that the app computes and shows:
   - **In a playlist:** in at least one Serato crate (Subcrates). SmartCrate membership doesn't count, because it's rule-derived.
   - **Cue points:** the file has Serato cue points.
   - **Beatgrid checked:** the beatgrid is locked or confirmed in Serato.
   - **Good metadata:** the required fields are present: artist, title, genre, BPM and key. This reuses Auto-Tag's existing "missing metadata" definition.
   - **Good quality:** passes a bitrate and format threshold. Lossless, or lossy at 256 kbps or more, is the default; it's the builder's call and should be one shared constant.
   - **Not over-versioned:** the track's song family has no more than a threshold of versions, or the track is the family's main version.
   - **Not a duplicate:** isn't in a confirmed duplicate group, other than as its keeper.

   A track that passes every item, or that the owner marked as a keeper (see 5), is **Finished**.
2. **Popularity signals** per track:
   - **All-time:** how well known it is overall.
   - **Hot:** how fast it's gaining now.
   - **My plays:** the owner's own Serato History play count (#34).

   The owner confirmed that both all-time and hot are useful in different ways.
3. **Library integration ("A", approved):**
   - New sortable columns: Popularity, Hot, My plays, Still needs (missing items as small text tags), and Date added (#43).
   - Filter chips with live counts: Needs work, Not in a crate, No cues, Grid unchecked, Low quality, Never played, Too many versions, Finished.
   - Everything combines with the existing search and the genre, BPM and key filters. Example: "artist X, sorted by Popularity, Needs work only".
4. **A Prepare workspace ("B", approved):**
   - It works through the unfinished tracks, most promising first. The builder chooses the ranking and documents it, for example popularity plus your plays.
   - It uses the same filters as the Library and shows one track, or one song family, at a time.
   - Each card shows what's missing and offers the fixes: Add to crate, Fix tags (through Auto-Tag), Open in Serato to check the grid, Play (the existing player), Mark as keeper, Show other versions, and Move to Trash.
5. **Keeper flag.** The owner can mark a track as a keeper, which protects it. It never appears as filler or a removal candidate, and it counts as Finished. This covers obscure gems. The flag is recording-level, so all encodings of one recording share it (Invariant 4), and setting or clearing it is an undoable mutation.
6. **Removal is deletion.** When the owner decides a track is filler, they want it gone from the library entirely, not hidden. Deletion goes through the existing reviewed, undoable path used by Duplicates cleanup: move to Trash, remove from V2, Subcrates and SmartCrates, record it in History, and undo while the file is still in the Trash. Prepare and the Library can select several tracks for one reviewed removal, which shows how much space it frees.
7. **Version attributes (#137).** Structured facets for content (Clean/Dirty/unknown) and arrangement (Main, Intro/Outro, Radio, Extended, Remix, Instrumental, Acapella, …). They're filterable, for example "clean instrumentals". Build on PR 244's `VersionLabel` vocabulary. Inference from titles is a *suggestion* that needs review, as #137 says.

## Non-goals (for this design)

- A target library size or track count.
- Reading anything from Spotify. Its February 2026 Web API changes removed track and artist `popularity` and the artist top-tracks endpoint, and limited Development Mode apps to 5 users with a Premium owner.
- USB or other-player export. That's tracked in #250, which also has to revisit Invariant 7 with the owner.
- Automatic deletion or automatic crate assignment.
- Editing cue points or beatgrids. crate-agent only reads them; preparation happens in Serato.

## Anti-goals (would be failures even if everything technically works)

The owner accepted these as the first-run list.

- **Deleting a gem because it scored low.** Signals only suggest. Every removal is the owner's explicit, reviewed choice, and it stays undoable while the file is in the Trash.
- **A slower Library.** At 30,000 files, the new columns, chips and counts meet the existing interaction budgets under Invariant 8: under 500 ms to sort or filter, and writer holds under 500 ms. Browsing stays available while signals are computed.
- **Lookups getting in the way.** Popularity lookups run in the background, are rate-limited, and are cached. The app works fully offline, and a missing score shows as "unknown", never as 0, and never sorts as least popular.
- **Quietly sending library data to outside services.** Only artist, title, ISRC and MusicBrainz IDs are sent. Each source can be switched on or off, and the first enable says what's sent where.
- **Writing Serato files while Serato is running.** Crate adds, tag fixes and removals keep Invariant 3. They queue and use `.seratoWriteGated` with a `SeratoRunningBanner`.

## Constraints and existing contracts

- **Invariant 1 / 2:** every state change, including keeper, crate add, version attribute and removal, is a `TrackMutation` through `OperationEngine`, with a complete `SeratoConflictTargets` projection and an inverse payload. Cached popularity data is derived observation data and doesn't need to be a mutation. The builder decides how it's stored and documents the choice: schema-only migrations, with writes through a service, never ad hoc.
- **Invariant 3:** the Serato crate add is a new Serato-side write. It must round-trip every crate-shaped file it touches.
- **Invariant 4:** popularity and keeper attach to the recording, not the path. Files without a `track_id` still need a key; use the existing MusicBrainz recording ID or file-level fallback rules, and say which.
- **Invariant 8:** this is large-library work, so the plan states journeys, budgets, the 30k fixture and an on-screen smoke checklist before implementation.
- **API first:** expose readiness, signals and filters through the service API that the views consume, not inside views.
- **UI rules:** no chevron or triangle disclosures, text-labelled controls, and strings used more than once go in a constants file.

## Decided by the owner

- The goal is a finished library, not a target size.
- Popularity matters both all-time and hot. Filler is mostly unpopular tracks, but not always, plus too many versions and duplicates.
- Removal means deletion from the library.
- "Prepared" means cue points, a checked beatgrid, good metadata, and being in a playlist.
- Both the Library integration (A) and the Prepare workspace (B).
- The anti-goals above.
- No Spotify, because its API no longer offers popularity. A USB export is wanted later (#250).

## My calls (not the owner's), open to change

- **Popularity sources, all tested live on 2026-10-17:**
  - **ListenBrainz** (`/1/popularity/recording`, `/1/popularity/top-recordings-for-artist`, no key, by MusicBrainz ID) as the primary source, because Auto-Tag already stores MusicBrainz IDs.
  - **Deezer** (`rank`, `/track/isrc:…`, `/artist/{id}/top`, no key) as the mainstream signal and an ISRC fallback.
  - **Last.fm** (`track.getInfo` listeners and playcount, free API key) as an optional third source.
  - Check Deezer's and Last.fm's terms on caching before building.
- **"Hot" is computed by crate-agent:** it re-checks counts on a schedule and keeps a short history, so Hot is growth over recent weeks. Deezer charts and ListenBrainz weekly top lists may seed it. None of these services offers a clean per-track trending number.
- **Showing popularity:** each source keeps its own raw value. The UI shows one normalized all-time score, and its tooltip lists the sources.
- **Date added (#43):** use Serato's `tadd` from V2 where present, and otherwise when crate-agent first indexed the file. Label it "Date added".
- **The quality threshold and the "too many versions" threshold** are single named constants the builder picks and documents.
- **Where keeper and popularity attach:** to the file's recording when `track_id` is set, so every encoding of that recording shares it. Otherwise they attach to the file itself. When a file later gains a `track_id`, its keeper flag moves to the recording through a mutation, never silently.
- **Add to crate:** offers the owner's existing Serato crates only. Creating, renaming or reorganizing crates belongs to #141, which is still undecided.
- **Popularity sources start switched off.** The first time the owner opens a popularity column or Prepare, one prompt explains what each source receives and lets them switch it on. Until then, Popularity shows "off", not "unknown".

## Left to the builder

- **Reading cue points and beatgrid lock from audio tags.** That means Serato's `Serato Markers2` and `Serato BeatGrid` frames, including whether Markers2's BPM-lock entry reliably means "grid checked". Use an established parser or reference, such as the documented serato-tags formats, rather than inventing one. If "checked" can't be read reliably, say so and fall back to "has a beatgrid", labelled honestly.
- **Crate membership per track:** probably from the crate parsing the Rust core already does, cached at sync time.
- Storage shape, refresh scheduling, rate limits and backoff for lookups.
- Prepare's ranking formula and its card layout details.
- How to split delivery into PRs. Suggested order: readiness checklist and Library columns and chips; popularity sources and Hot; Prepare workspace; version attributes (#137).
