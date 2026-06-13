use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::types::AcquisitionRecord;

/// Write one acquisition manifest next to its audio file in `staging/`.
/// The manifest filename is the audio filename with `.json` appended.
pub fn write_manifest(staging_dir: &Path, record: &AcquisitionRecord) -> Result<PathBuf> {
    std::fs::create_dir_all(staging_dir)?;
    let audio_name = Path::new(&record.file_path)
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "download".to_string());
    let manifest_path = staging_dir.join(format!("{audio_name}.json"));
    let json = serde_json::to_string_pretty(record)?;
    std::fs::write(&manifest_path, json)?;
    Ok(manifest_path)
}

/// Read one acquisition manifest back.
pub fn read_manifest(manifest_path: &Path) -> Result<AcquisitionRecord> {
    let json = std::fs::read_to_string(manifest_path)?;
    Ok(serde_json::from_str(&json)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{FormatPreference, ListEntry, SourceInfo};

    fn record() -> AcquisitionRecord {
        AcquisitionRecord {
            list_entry: ListEntry {
                artist: "Daft Punk".into(),
                title: "Around the World".into(),
                album: None,
                year: None,
                duration_secs: Some(429),
                isrc: None,
                musicbrainz_recording_id: None,
                format_preference: FormatPreference::Any,
            },
            file_path: "/tmp/staging/track.flac".into(),
            fingerprint: vec![1, 2, 3, 4],
            source: SourceInfo {
                slskd_username: "dj_alice".into(),
                original_filename: "Daft Punk - Around the World.flac".into(),
                bitrate_kbps: None,
                format: "flac".into(),
                size_bytes: 41000000,
            },
            confirmed: true,
        }
    }

    #[test]
    fn manifest_round_trips() {
        let dir = std::env::temp_dir().join("crate-agent-test-staging");
        std::fs::create_dir_all(&dir).unwrap();
        let path = write_manifest(&dir, &record()).unwrap();
        let loaded = read_manifest(&path).unwrap();
        assert_eq!(loaded, record());
        std::fs::remove_file(&path).ok();
    }
}
