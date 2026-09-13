// Audio file tag I/O via `lofty`.
//
// SP-1 uses this for *reading* tags only — the filename template engine
// (Pillar A's manual rename UI, Pillar A-proactive's rule engine in
// SP-3) needs `$artist`, `$title`, `$mixtype`, etc. populated from the
// file's existing metadata.
//
// Tag *writing* lands in SP-1.5 (library hygiene) and is used heavily
// by SP-2 (MusicBrainz auto-tagger) and Pillar F (re-encoding metadata
// propagation).
//
// `lofty` exposes a unified `Accessor` trait across every audio format
// Serato supports — ID3v2 (MP3/AIFF), iTunes atoms (M4A/MP4), Vorbis
// comments (FLAC/OGG), and RIFF INFO (WAV) — so the caller doesn't
// need to know the file type.

use std::path::Path;

use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::items::Timestamp;
use lofty::tag::{ItemKey, Tag};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TagError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("could not probe file: {0}")]
    Probe(String),
    #[error("could not read tags: {0}")]
    Read(String),
    #[error("could not write tags: {0}")]
    Write(String),
}

/// Tag fields extracted from an audio file. All fields are optional —
/// many real-world files have partial or missing tags. Filename
/// templates substitute an empty string when a referenced field is
/// `None`; the template engine is the right place to add fallback
/// behavior, not this module.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub track_number: Option<u32>,
    pub total_tracks: Option<u32>,
    pub bpm: Option<f64>,
    pub comment: Option<String>,
    pub duration_seconds: Option<u64>,
    /// Audio bitrate in kilobits per second from `lofty`'s audio
    /// properties. Used by the duplicate-resolver's keeper picker
    /// to rank perceptual matches by encoding quality.
    pub bitrate_kbps: Option<u32>,
}

pub fn read_tags(path: impl AsRef<Path>) -> Result<AudioTags, TagError> {
    let probe = Probe::open(path.as_ref()).map_err(|err| TagError::Probe(err.to_string()))?;
    let tagged_file = probe.read().map_err(|err| TagError::Read(err.to_string()))?;

    let mut tags = AudioTags::default();

    let properties = tagged_file.properties();
    tags.duration_seconds = Some(properties.duration().as_secs());
    // `audio_bitrate()` returns `Option<u32>` — `None` when the
    // format doesn't carry a bitrate (e.g., some lossless containers)
    // and otherwise the value in kbps. Pass through verbatim; the
    // keeper picker treats `None` as "unknown bitrate" rather than 0.
    tags.bitrate_kbps = properties.audio_bitrate().filter(|kbps| *kbps > 0);

    if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
        tags.title = tag.title().map(|cow| cow.into_owned());
        tags.artist = tag.artist().map(|cow| cow.into_owned());
        tags.album = tag.album().map(|cow| cow.into_owned());
        tags.genre = tag.genre().map(|cow| cow.into_owned());
        // `Accessor::date()` reads `ItemKey::RecordingDate` (ID3v2.4 `TDRC` /
        // Vorbis `DATE` / iTunes `©day`) falling back to the legacy
        // `ItemKey::Year`, and parses whatever subset of the timestamp is
        // present. `write_tags` below writes through the same accessor, so
        // this must stay paired with `set_date` rather than reading
        // `ItemKey::Year` directly.
        tags.year = tag.date().map(|timestamp| u32::from(timestamp.year));
        tags.track_number = tag.track();
        tags.total_tracks = tag.track_total();
        tags.comment = tag.comment().map(|cow| cow.into_owned());
        tags.album_artist = tag.get_string(ItemKey::AlbumArtist).map(String::from);
        tags.bpm = tag.get_string(ItemKey::Bpm).and_then(|value| value.parse::<f64>().ok());
    }

    Ok(tags)
}

/// Patch to apply to an audio file's primary tag. Mirrors the
/// `SeratoMetadata` Swift struct field-for-field so the FFI binding
/// is a direct pass-through; the runner doesn't translate fields.
/// Every value is optional — `None` leaves the existing tag content
/// alone, `Some(value)` overwrites (empty string overwrites with
/// empty).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioTagUpdate {
    pub artist: Option<String>,
    pub title: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub bpm: Option<String>,
    pub musical_key: Option<String>,
    pub comment: Option<String>,
    pub label: Option<String>,
    pub year: Option<u32>,
    /// Remove the file's date/year frame outright. `Option<u32>` cannot
    /// express "clear" — `None` means leave-unchanged — so undoing a
    /// match that added a year to a file with no prior year needs this
    /// explicit flag. Takes precedence over `year`: when true, `year` is
    /// ignored and the date frame is removed.
    pub clear_year: bool,
}

/// Write the supplied fields to the audio file's primary tag. For
/// MP3, Lofty's default `WriteOptions` writes **ID3v2.4** (the
/// current spec — UTF-8 support, sync-safe sizes); calling
/// `remove_others(true)` strips any legacy tags (ID3v1, APE) that
/// would otherwise lie on top of the v2.4 tag with stale values.
///
/// FLAC files get Vorbis comments, M4A gets iTunes atoms, etc. —
/// Lofty's `primary_tag_mut` dispatches on the file type.
///
/// If the file has no tag at all, one is created in the file's
/// natural primary type before fields are set.
pub fn write_tags(path: impl AsRef<Path>, update: &AudioTagUpdate) -> Result<(), TagError> {
    let path_ref = path.as_ref();
    let probe = Probe::open(path_ref).map_err(|err| TagError::Probe(err.to_string()))?;
    let mut tagged_file = probe.read().map_err(|err| TagError::Read(err.to_string()))?;

    if tagged_file.primary_tag().is_none() {
        let primary_type = tagged_file.primary_tag_type();
        tagged_file.insert_tag(Tag::new(primary_type));
    }

    let tag = tagged_file
        .primary_tag_mut()
        .expect("primary tag was inserted above if it didn't exist");

    apply_update_to_tag(tag, update);

    let opts = WriteOptions::new().remove_others(true);
    tagged_file
        .save_to_path(path_ref, opts)
        .map_err(|err| TagError::Write(err.to_string()))?;

    Ok(())
}

/// Pull-out so the apply logic is unit-testable against a free-
/// standing `Tag` without needing real file I/O.
fn apply_update_to_tag(tag: &mut Tag, update: &AudioTagUpdate) {
    if let Some(value) = &update.artist {
        tag.set_artist(value.clone());
    }
    if let Some(value) = &update.title {
        tag.set_title(value.clone());
    }
    if let Some(value) = &update.album {
        tag.set_album(value.clone());
    }
    if let Some(value) = &update.genre {
        tag.set_genre(value.clone());
    }
    if let Some(value) = &update.comment {
        tag.set_comment(value.clone());
    }
    if let Some(value) = &update.bpm {
        tag.insert_text(ItemKey::Bpm, value.clone());
    }
    if let Some(value) = &update.musical_key {
        tag.insert_text(ItemKey::InitialKey, value.clone());
    }
    if let Some(value) = &update.label {
        tag.insert_text(ItemKey::Label, value.clone());
    }
    if update.clear_year {
        // Undo of a match that added a year to a previously-yearless
        // file: remove the date frame entirely rather than leaving the
        // added value in place (which `year: None` would do).
        tag.remove_date();
    } else if let Some(year) = update.year {
        // `Timestamp::year` is a `u16`; release years never approach that
        // range, but clamp rather than panic on an out-of-range input.
        let year = u16::try_from(year).unwrap_or(u16::MAX);
        tag.set_date(Timestamp {
            year,
            ..Timestamp::default()
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    const SAMPLE_RATE: u32 = 44_100;
    const CHANNELS: u16 = 1;

    /// Mono 16-bit PCM WAV file — duplicate of the helper in fingerprint::tests
    /// kept local because tests don't share helper modules and the format is
    /// trivial.
    fn write_silent_wav(path: &Path, duration_seconds: u32) -> std::io::Result<()> {
        let total_samples = (SAMPLE_RATE * duration_seconds) as usize;
        let byte_rate = SAMPLE_RATE * CHANNELS as u32 * 2;
        let data_size = (total_samples * 2) as u32;
        let chunk_size = 36 + data_size;

        let mut file = std::fs::File::create(path)?;
        file.write_all(b"RIFF")?;
        file.write_all(&chunk_size.to_le_bytes())?;
        file.write_all(b"WAVE")?;
        file.write_all(b"fmt ")?;
        file.write_all(&16u32.to_le_bytes())?;
        file.write_all(&1u16.to_le_bytes())?;
        file.write_all(&CHANNELS.to_le_bytes())?;
        file.write_all(&SAMPLE_RATE.to_le_bytes())?;
        file.write_all(&byte_rate.to_le_bytes())?;
        file.write_all(&(CHANNELS * 2).to_le_bytes())?;
        file.write_all(&16u16.to_le_bytes())?;
        file.write_all(b"data")?;
        file.write_all(&data_size.to_le_bytes())?;
        for _ in 0..total_samples {
            file.write_all(&0i16.to_le_bytes())?;
        }
        Ok(())
    }

    #[test]
    fn reads_audio_properties_from_untagged_wav() {
        let tmpdir = std::env::temp_dir().join("crate-agent-test-tags-untagged");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("silent.wav");

        write_silent_wav(&path, 5).unwrap();
        let tags = read_tags(&path).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(tags.duration_seconds, Some(5), "duration must be populated from properties");
        assert_eq!(tags.title, None, "no tags written, no title expected");
        assert_eq!(tags.artist, None);
        assert_eq!(tags.album, None);
        assert_eq!(tags.year, None);
    }

    #[test]
    fn round_trips_written_tags_through_lofty() {
        // Write a WAV, attach RIFF INFO tags via lofty's writer, then
        // verify our reader extracts them. This exercises the unified
        // Accessor path lofty offers across formats.
        use lofty::file::AudioFile;
        use lofty::tag::{Tag, TagType};

        let tmpdir = std::env::temp_dir().join("crate-agent-test-tags-roundtrip");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("tagged.wav");

        write_silent_wav(&path, 3).unwrap();

        let mut tagged_file = Probe::open(&path).unwrap().read().unwrap();
        let mut tag = Tag::new(TagType::RiffInfo);
        // Fields that round-trip reliably through RIFF INFO (the WAV
        // tag format lofty chose for us). Year is exercised separately
        // in `writes_and_reads_year`, via `set_date`/`date` rather than
        // this test's direct `Tag` construction.
        tag.set_title("Test Title".to_string());
        tag.set_artist("Test Artist".to_string());
        tag.set_album("Test Album".to_string());
        tag.set_genre("House".to_string());
        tag.set_track(7);

        tagged_file.insert_tag(tag);
        tagged_file.save_to_path(&path, lofty::config::WriteOptions::default()).unwrap();

        let read_back = read_tags(&path).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(read_back.title.as_deref(), Some("Test Title"));
        assert_eq!(read_back.artist.as_deref(), Some("Test Artist"));
        assert_eq!(read_back.album.as_deref(), Some("Test Album"));
        assert_eq!(read_back.genre.as_deref(), Some("House"));
        assert_eq!(read_back.track_number, Some(7));
        assert_eq!(read_back.duration_seconds, Some(3));
    }

    #[test]
    fn returns_probe_error_for_nonexistent_file() {
        let result = read_tags("/nonexistent/path/to/audio.mp3");
        assert!(matches!(result, Err(TagError::Probe(_))));
    }

    #[test]
    fn write_tags_round_trips_text_fields_into_existing_tag() {
        let tmpdir = std::env::temp_dir().join("crate-agent-test-write-roundtrip");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("write.wav");
        write_silent_wav(&path, 2).unwrap();

        // Seed the file with one set of values so we can confirm the
        // update overwrites rather than appending.
        let update_initial = AudioTagUpdate {
            artist: Some("Old Artist".to_string()),
            title: Some("Old Title".to_string()),
            ..Default::default()
        };
        write_tags(&path, &update_initial).unwrap();

        let update = AudioTagUpdate {
            artist: Some("New Artist".to_string()),
            title: Some("New Title".to_string()),
            album: Some("New Album".to_string()),
            genre: Some("House".to_string()),
            comment: Some("Edited via crate-agent".to_string()),
            // bpm / musical_key / label are intentionally passed
            // through here even though WAV's RIFF INFO doesn't have
            // mappings for them — proves write_tags doesn't error
            // on unsupported keys (Lofty silently drops them in the
            // RIFF INFO case). Round-trip of these fields is
            // exercised against real-format fixtures in higher-
            // fidelity tests.
            bpm: Some("128.000".to_string()),
            musical_key: Some("Am".to_string()),
            label: Some("Test Label".to_string()),
            // Year has a dedicated round-trip test (`writes_and_reads_year`).
            year: None,
            clear_year: false,
        };
        write_tags(&path, &update).unwrap();

        let read_back = read_tags(&path).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(read_back.artist.as_deref(), Some("New Artist"));
        assert_eq!(read_back.title.as_deref(), Some("New Title"));
        assert_eq!(read_back.album.as_deref(), Some("New Album"));
        assert_eq!(read_back.genre.as_deref(), Some("House"));
        assert_eq!(read_back.comment.as_deref(), Some("Edited via crate-agent"));
    }

    #[test]
    fn write_tags_leaves_unspecified_fields_alone() {
        let tmpdir = std::env::temp_dir().join("crate-agent-test-write-partial");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("partial.wav");
        write_silent_wav(&path, 2).unwrap();

        // Seed.
        write_tags(
            &path,
            &AudioTagUpdate {
                artist: Some("Keep Me".to_string()),
                title: Some("Keep Me Too".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        // Update only `artist`. `title` must survive untouched.
        write_tags(
            &path,
            &AudioTagUpdate {
                artist: Some("Updated".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        let read_back = read_tags(&path).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(read_back.artist.as_deref(), Some("Updated"));
        assert_eq!(
            read_back.title.as_deref(),
            Some("Keep Me Too"),
            "fields with None in the update must be preserved verbatim"
        );
    }

    #[test]
    fn writes_and_reads_year() {
        let tmpdir = std::env::temp_dir().join("crate-agent-test-write-year");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("year.wav");
        write_silent_wav(&path, 2).unwrap();

        let update = AudioTagUpdate { year: Some(1994), ..AudioTagUpdate::default() };
        write_tags(&path, &update).unwrap();

        let read_back = read_tags(&path).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(read_back.year, Some(1994));
    }

    /// The undo path relies on `apply_update_to_tag` distinguishing
    /// "clear this field" (`Some(""))` from "leave it alone" (`None`).
    /// Verified directly against a free-standing `Tag` — no file I/O — so
    /// the semantics are pinned independent of any format's on-save
    /// handling of empty frames.
    #[test]
    fn empty_string_clears_text_field_none_leaves_it_intact() {
        use lofty::tag::{Tag, TagType};

        let mut tag = Tag::new(TagType::Id3v2);
        tag.set_artist("Original Artist".to_string());
        tag.set_album("Original Album".to_string());

        // artist -> Some("") clears; album -> None leaves untouched.
        let update = AudioTagUpdate {
            artist: Some(String::new()),
            ..Default::default()
        };
        apply_update_to_tag(&mut tag, &update);

        assert!(
            tag.artist().is_none_or(|value| value.is_empty()),
            "Some(\"\") must clear the tag, not leave the prior value"
        );
        assert_eq!(
            tag.album().as_deref(),
            Some("Original Album"),
            "None must leave the prior value intact"
        );
    }

    /// `clear_year` removes the date frame; `year: None` alone leaves it.
    #[test]
    fn clear_year_removes_date_frame() {
        use lofty::tag::{Tag, TagType};

        let mut tag = Tag::new(TagType::Id3v2);
        tag.set_date(Timestamp {
            year: 1994,
            ..Timestamp::default()
        });
        assert_eq!(tag.date().map(|timestamp| timestamp.year), Some(1994));

        // year: None must NOT clear the existing date.
        apply_update_to_tag(&mut tag, &AudioTagUpdate::default());
        assert_eq!(
            tag.date().map(|timestamp| timestamp.year),
            Some(1994),
            "year: None with clear_year: false must leave the date frame alone"
        );

        // clear_year: true removes it.
        apply_update_to_tag(
            &mut tag,
            &AudioTagUpdate {
                clear_year: true,
                ..Default::default()
            },
        );
        assert_eq!(tag.date(), None, "clear_year must remove the date frame");
    }

    #[test]
    fn write_tags_creates_tag_when_file_has_none() {
        let tmpdir = std::env::temp_dir().join("crate-agent-test-write-no-tag");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("no-tag.wav");
        write_silent_wav(&path, 2).unwrap();

        // No tag was written above. The function should create one.
        write_tags(
            &path,
            &AudioTagUpdate {
                artist: Some("Fresh Artist".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        let read_back = read_tags(&path).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(read_back.artist.as_deref(), Some("Fresh Artist"));
    }
}
