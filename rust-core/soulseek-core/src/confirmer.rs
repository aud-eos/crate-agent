use std::path::Path;

use crate::error::{Result, SoulseekError};
use crate::types::ListEntry;

/// Tolerance when comparing an entry's expected duration to the
/// downloaded file's actual duration.
pub const DURATION_CONFIRM_TOLERANCE_SECS: u64 = 8;

/// The verdict on a freshly downloaded file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Confirmation {
    pub fingerprint: Vec<u32>,
    pub duration_secs: u64,
    pub format: String,
    pub bitrate_kbps: Option<u32>,
    pub confirmed: bool,
    /// Populated when `confirmed == false`.
    pub reason: Option<String>,
}

/// Verify a downloaded file is real, decodable audio of roughly the
/// expected length, and compute its Chromaprint fingerprint (recorded
/// in the manifest for Phase 2 placeholder matching). A decode failure
/// is a hard error — the caller parks the entry rather than confirming.
pub fn confirm_download(file_path: &Path, entry: &ListEntry) -> Result<Confirmation> {
    use lofty::file::AudioFile;
    use lofty::probe::Probe;

    let fingerprint = fingerprint_core::fingerprint_file(file_path)
        .map_err(|error| SoulseekError::Confirm(format!("decode/fingerprint failed: {error}")))?;
    if fingerprint.is_empty() {
        return Err(SoulseekError::Confirm("fingerprint was empty".into()));
    }

    let tagged = Probe::open(file_path)
        .map_err(|error| SoulseekError::Confirm(format!("cannot open audio: {error}")))?
        .read()
        .map_err(|error| {
            SoulseekError::Confirm(format!("cannot read audio properties: {error}"))
        })?;
    let properties = tagged.properties();
    let duration_secs = properties.duration().as_secs();
    let bitrate_kbps = properties.audio_bitrate();
    let format = file_path
        .extension()
        .and_then(|os_str| os_str.to_str())
        .map(|extension| extension.to_lowercase())
        .unwrap_or_default();

    let (confirmed, reason) = match entry.duration_secs {
        Some(expected) if duration_secs.abs_diff(expected) > DURATION_CONFIRM_TOLERANCE_SECS => (
            false,
            Some(format!(
                "duration {duration_secs}s differs from expected {expected}s"
            )),
        ),
        _ => (true, None),
    };

    Ok(Confirmation {
        fingerprint,
        duration_secs,
        format,
        bitrate_kbps,
        confirmed,
        reason,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::FormatPreference;

    fn write_sine_wav(path: &Path, seconds: u32) {
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 44_100,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut writer = hound::WavWriter::create(path, spec).unwrap();
        let total = 44_100 * seconds;
        for index in 0..total {
            let time = index as f32 / 44_100.0;
            let sample = (time * 440.0 * 2.0 * std::f32::consts::PI).sin();
            writer
                .write_sample((sample * i16::MAX as f32) as i16)
                .unwrap();
        }
        writer.finalize().unwrap();
    }

    fn entry(duration: Option<u64>) -> ListEntry {
        ListEntry {
            artist: "T".into(),
            title: "S".into(),
            album: None,
            year: None,
            duration_secs: duration,
            isrc: None,
            musicbrainz_recording_id: None,
            format_preference: FormatPreference::Any,
        }
    }

    #[test]
    fn confirms_valid_audio_matching_expected_duration() {
        let dir = std::env::temp_dir().join("crate-agent-test-confirm-ok");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ok.wav");
        write_sine_wav(&path, 12);
        let confirmation = confirm_download(&path, &entry(Some(12))).unwrap();
        std::fs::remove_file(&path).ok();
        assert!(confirmation.confirmed);
        assert!(!confirmation.fingerprint.is_empty());
        assert_eq!(confirmation.format, "wav");
    }

    #[test]
    fn flags_duration_mismatch_but_still_fingerprints() {
        let dir = std::env::temp_dir().join("crate-agent-test-confirm-drift");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("short.wav");
        write_sine_wav(&path, 5);
        let confirmation = confirm_download(&path, &entry(Some(300))).unwrap();
        std::fs::remove_file(&path).ok();
        assert!(!confirmation.confirmed);
        assert!(confirmation.reason.is_some());
        assert!(!confirmation.fingerprint.is_empty());
    }

    #[test]
    fn undecodable_file_is_a_hard_error() {
        let dir = std::env::temp_dir().join("crate-agent-test-confirm-bad");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("garbage.mp3");
        std::fs::write(&path, b"not audio at all").unwrap();
        let result = confirm_download(&path, &entry(None));
        std::fs::remove_file(&path).ok();
        assert!(matches!(result, Err(SoulseekError::Confirm(_))));
    }
}
