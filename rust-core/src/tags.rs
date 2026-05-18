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

use lofty::file::TaggedFileExt;
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::ItemKey;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TagError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("could not probe file: {0}")]
    Probe(String),
    #[error("could not read tags: {0}")]
    Read(String),
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
}

pub fn read_tags(path: impl AsRef<Path>) -> Result<AudioTags, TagError> {
    let probe = Probe::open(path.as_ref()).map_err(|err| TagError::Probe(err.to_string()))?;
    let tagged_file = probe.read().map_err(|err| TagError::Read(err.to_string()))?;

    let mut tags = AudioTags::default();

    let properties = tagged_file.properties();
    tags.duration_seconds = Some(properties.duration().as_secs());

    if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
        tags.title = tag.title().map(|cow| cow.into_owned());
        tags.artist = tag.artist().map(|cow| cow.into_owned());
        tags.album = tag.album().map(|cow| cow.into_owned());
        tags.genre = tag.genre().map(|cow| cow.into_owned());
        tags.year = tag.get_string(ItemKey::Year).and_then(|value| value.parse::<u32>().ok());
        tags.track_number = tag.track();
        tags.total_tracks = tag.track_total();
        tags.comment = tag.comment().map(|cow| cow.into_owned());
        tags.album_artist = tag.get_string(ItemKey::AlbumArtist).map(String::from);
        tags.bpm = tag.get_string(ItemKey::Bpm).and_then(|value| value.parse::<f64>().ok());
    }

    Ok(tags)
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
        // tag format lofty chose for us). Year is intentionally omitted
        // because the lofty 0.24 Accessor trait lacks set_year and the
        // RIFF INFO mapping for ItemKey::Year is one-way on read but
        // not on write — those are exercised against ID3-tagged files
        // in higher-fidelity tests once we have real fixtures.
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
}
