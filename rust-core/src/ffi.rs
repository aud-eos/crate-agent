use std::collections::HashMap;
use std::path::PathBuf;

use thiserror::Error;

use crate::serato;
use crate::tags;
use fingerprint_core as fingerprint;

pub use crate::serato::{SeratoMetadataUpdate, SeratoTrackRecord};
pub use crate::tags::{AudioTagUpdate, AudioTags};

/// One rename pair in a `batch_rewrite_*` call. UniFFI doesn't take
/// tuples, so the (old, new) pair is wrapped in a dictionary.
#[derive(Debug, Clone)]
pub struct SeratoPathRename {
    pub old_path: String,
    pub new_path: String,
}

/// One track's metadata update in a `batch_update_database_records`
/// call. UniFFI doesn't take maps of structs, so the `(path, update)`
/// pair is wrapped in a dictionary — the batch twin of
/// `SeratoPathRename`.
#[derive(Debug, Clone)]
pub struct SeratoTrackMetadataUpdate {
    pub track_path: String,
    pub update: SeratoMetadataUpdate,
}

/// One track in a `batch_add_tracks_to_database` call.
#[derive(Debug, Clone)]
pub struct SeratoTrackAddition {
    pub track_path: String,
    pub metadata: SeratoMetadataUpdate,
}

/// Renames apply in order. The rewrite looks each record up once, so a
/// rename of an earlier rename's destination (old → middle, middle → new)
/// is folded into that chain to land the record at its final path.
fn rename_map(renames: &[SeratoPathRename]) -> HashMap<String, String> {
    let mut map: HashMap<String, String> = HashMap::new();
    let mut origins_by_destination: HashMap<String, Vec<String>> = HashMap::new();
    for rename in renames
        .iter()
        .filter(|rename| rename.old_path != rename.new_path)
    {
        let mut origins = origins_by_destination
            .remove(&rename.old_path)
            .unwrap_or_default();
        if !map.contains_key(&rename.old_path) {
            origins.push(rename.old_path.clone());
        }
        for origin in &origins {
            map.insert(origin.clone(), rename.new_path.clone());
        }
        origins_by_destination
            .entry(rename.new_path.clone())
            .or_default()
            .extend(origins);
    }
    map.retain(|old_path, new_path| old_path != new_path);
    map
}

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("not implemented")]
    NotImplemented,
    #[error("invalid input: {reason}")]
    InvalidInput { reason: String },
    #[error("io error: {message}")]
    IoError { message: String },
    #[error("serato format error: {message}")]
    SeratoFormat { message: String },
    #[error("fingerprint error: {message}")]
    Fingerprint { message: String },
    #[error("tag error: {message}")]
    Tag { message: String },
}

impl From<std::io::Error> for CoreError {
    fn from(err: std::io::Error) -> Self {
        CoreError::IoError {
            message: err.to_string(),
        }
    }
}

impl From<serato::SeratoError> for CoreError {
    fn from(err: serato::SeratoError) -> Self {
        match err {
            serato::SeratoError::Io(io_err) => CoreError::IoError {
                message: io_err.to_string(),
            },
            other => CoreError::SeratoFormat {
                message: other.to_string(),
            },
        }
    }
}

impl From<fingerprint::FingerprintError> for CoreError {
    fn from(err: fingerprint::FingerprintError) -> Self {
        match err {
            fingerprint::FingerprintError::Io(io_err) => CoreError::IoError {
                message: io_err.to_string(),
            },
            other => CoreError::Fingerprint {
                message: other.to_string(),
            },
        }
    }
}

impl From<tags::TagError> for CoreError {
    fn from(err: tags::TagError) -> Self {
        match err {
            tags::TagError::Io(io_err) => CoreError::IoError {
                message: io_err.to_string(),
            },
            other => CoreError::Tag {
                message: other.to_string(),
            },
        }
    }
}

pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

pub fn read_crate_paths(crate_path: String) -> Result<Vec<String>, CoreError> {
    let path = PathBuf::from(crate_path);
    let crate_file = serato::CrateFile::read_from_path(&path)?;
    Ok(crate_file.track_paths())
}

pub fn rewrite_crate_path(
    crate_path: String,
    old_path: String,
    new_path: String,
) -> Result<u32, CoreError> {
    if old_path == new_path {
        return Ok(0);
    }
    let path = PathBuf::from(crate_path);
    let mut crate_file = serato::CrateFile::read_from_path(&path)?;
    let count = crate_file.rewrite_path(&old_path, &new_path);
    if count > 0 {
        crate_file.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("rewrite count exceeded u32"))
}

pub fn read_database_paths(database_path: String) -> Result<Vec<String>, CoreError> {
    let path = PathBuf::from(database_path);
    let database = serato::DatabaseV2::read_from_path(&path)?;
    Ok(database.track_paths())
}

pub fn rewrite_database_path(
    database_path: String,
    old_path: String,
    new_path: String,
) -> Result<u32, CoreError> {
    if old_path == new_path {
        return Ok(0);
    }
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let count = database.rewrite_path(&old_path, &new_path);
    if count > 0 {
        database.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("rewrite count exceeded u32"))
}

/// Bulk variant of `rewrite_database_path`. One file read + one file
/// write regardless of how many renames are batched. Used by bulk
/// Organize / Migrate, which would otherwise read+rewrite a multi-MB
/// `database V2` file once per moved track.
pub fn batch_rewrite_database_paths(
    database_path: String,
    renames: Vec<SeratoPathRename>,
) -> Result<u32, CoreError> {
    let map = rename_map(&renames);
    if map.is_empty() {
        return Ok(0);
    }
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let count = database.rewrite_paths(&map);
    if count > 0 {
        database.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("rewrite count exceeded u32"))
}

/// Bulk variant of `rewrite_crate_path`. One file read + one file
/// write per crate file, regardless of how many renames apply within
/// that crate. Symmetric counterpart to `batch_rewrite_database_paths`.
pub fn batch_rewrite_crate_paths(
    crate_path: String,
    renames: Vec<SeratoPathRename>,
) -> Result<u32, CoreError> {
    let map = rename_map(&renames);
    if map.is_empty() {
        return Ok(0);
    }
    let path = PathBuf::from(crate_path);
    let mut crate_file = serato::CrateFile::read_from_path(&path)?;
    let count = crate_file.rewrite_paths(&map);
    if count > 0 {
        crate_file.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("rewrite count exceeded u32"))
}

pub fn remove_track_from_database(
    database_path: String,
    track_path: String,
) -> Result<u32, CoreError> {
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let count = database.remove_track(&track_path);
    if count > 0 {
        database.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("remove count exceeded u32"))
}

pub fn remove_path_from_crate(crate_path: String, track_path: String) -> Result<u32, CoreError> {
    let path = PathBuf::from(crate_path);
    let mut crate_file = serato::CrateFile::read_from_path(&path)?;
    let count = crate_file.remove_track(&track_path);
    if count > 0 {
        crate_file.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("remove count exceeded u32"))
}

pub fn database_track_count(database_path: String) -> Result<u32, CoreError> {
    let path = PathBuf::from(database_path);
    let database = serato::DatabaseV2::read_from_path(&path)?;
    Ok(u32::try_from(database.track_count()).expect("track count exceeded u32"))
}

pub fn read_database_records(database_path: String) -> Result<Vec<SeratoTrackRecord>, CoreError> {
    let path = PathBuf::from(database_path);
    let database = serato::DatabaseV2::read_from_path(&path)?;
    Ok(database.track_records())
}

pub fn read_database_records_strict(
    database_path: String,
) -> Result<Vec<SeratoTrackRecord>, CoreError> {
    let database = serato::DatabaseV2::read_from_path(database_path)?;
    Ok(database.strict_track_records()?)
}

pub fn update_database_record(
    database_path: String,
    track_path: String,
    update: SeratoMetadataUpdate,
) -> Result<u32, CoreError> {
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let count = database.update_track_metadata(&track_path, &update);
    if count > 0 {
        database.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("update count exceeded u32"))
}

/// Bulk variant of `update_database_record`. One file read + one file
/// write regardless of how many tracks are updated. Used by the SP-2
/// Auto-Tag apply, which confirms many MusicBrainz matches at once —
/// each would otherwise read+rewrite the (multi-MB) `database V2` file
/// on its own. Returns the number of otrks actually changed.
pub fn batch_update_database_records(
    database_path: String,
    updates: Vec<SeratoTrackMetadataUpdate>,
) -> Result<u32, CoreError> {
    if updates.is_empty() {
        return Ok(0);
    }
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let map: HashMap<String, SeratoMetadataUpdate> = updates
        .into_iter()
        .map(|entry| (entry.track_path, entry.update))
        .collect();
    let count = database.batch_update_track_metadata(&map);
    if count > 0 {
        database.write_to_path(&path)?;
    }
    Ok(u32::try_from(count).expect("update count exceeded u32"))
}

/// Bulk import registration: one file read + one file write, with the
/// library's existing paths collected once, regardless of how many tracks
/// are added. Returns the number of otrks appended; additions Serato
/// already holds are skipped.
pub fn batch_add_tracks_to_database(
    database_path: String,
    additions: Vec<SeratoTrackAddition>,
) -> Result<u32, CoreError> {
    if additions.is_empty() {
        return Ok(0);
    }
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let pairs: Vec<(String, SeratoMetadataUpdate)> = additions
        .into_iter()
        .map(|addition| (addition.track_path, addition.metadata))
        .collect();
    let added = database
        .add_tracks(&pairs)
        .into_iter()
        .filter(|added| *added)
        .count();
    if added > 0 {
        database.write_to_path(&path)?;
    }
    Ok(u32::try_from(added).expect("add count exceeded u32"))
}

pub fn fingerprint_audio_file(file_path: String) -> Result<Vec<u32>, CoreError> {
    let path = PathBuf::from(file_path);
    Ok(fingerprint::fingerprint_file(&path)?)
}

/// Encode a raw Chromaprint fingerprint into the compressed, base64url
/// string AcoustID's lookup API expects. Consumes the `Vec<u32>`
/// `fingerprint_audio_file` produces; the two are always used together
/// by the AcoustID lookup path.
pub fn encode_fingerprint(raw: Vec<u32>) -> String {
    fingerprint::encode_fingerprint_to_base64(&raw)
}

pub fn read_audio_tags(file_path: String) -> Result<AudioTags, CoreError> {
    let path = PathBuf::from(file_path);
    Ok(tags::read_tags(&path)?)
}

pub fn write_audio_tags(file_path: String, update: AudioTagUpdate) -> Result<(), CoreError> {
    let path = PathBuf::from(file_path);
    tags::write_tags(&path, &update)?;
    Ok(())
}

#[cfg(test)]
mod conflict_round_trip_tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn raw_record(tag: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut bytes = tag.to_vec();
        bytes.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_be_bytes());
        bytes.extend_from_slice(payload);
        bytes
    }

    fn raw_text(tag: &[u8; 4], text: &str) -> Vec<u8> {
        let payload: Vec<u8> = text.encode_utf16().flat_map(u16::to_be_bytes).collect();
        raw_record(tag, &payload)
    }

    fn raw_track(path_tag: &[u8; 4], path: &str, artist: &str, opaque: &[u8]) -> Vec<u8> {
        let mut payload = raw_text(path_tag, path);
        payload.extend(raw_text(b"tart", artist));
        payload.extend(raw_record(b"zzzz", opaque));
        raw_record(b"otrk", &payload)
    }

    fn metadata(artist: &str) -> SeratoMetadataUpdate {
        SeratoMetadataUpdate {
            artist: Some(artist.to_owned()),
            title: None,
            album: None,
            genre: None,
            bpm: None,
            key: None,
            comment: None,
            length: None,
            label: None,
        }
    }

    #[test]
    fn unrelated_ffi_writes_preserve_unicode_conflict_records_byte_for_byte() {
        let directory = std::env::temp_dir().join(format!(
            "crate-conflict-round-trip-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        let composed = "Music/Caf\u{e9}.mp3";
        let decomposed = "Music/Cafe\u{301}.mp3";
        assert_ne!(composed.as_bytes(), decomposed.as_bytes());
        for (name, path_tag, version) in [
            ("database V2", b"pfil", "2.0/Serato Scratch LIVE Database"),
            ("test.crate", b"ptrk", "1.0/Serato ScratchLive Crate"),
            ("test.scrate", b"ptrk", "1.0/Serato ScratchLive Crate"),
        ] {
            let path = directory.join(name).to_str().unwrap().to_owned();
            let first = raw_track(path_tag, composed, "First artist", &[0, 255, 7, 3]);
            let mut protected = raw_text(b"vrsn", version);
            protected.extend_from_slice(&first);
            protected.extend(raw_track(path_tag, decomposed, "Second artist", &[3, 2, 1]));
            protected.extend_from_slice(&first);
            let mut original = protected.clone();
            original.extend(raw_track(path_tag, "Music/Other.mp3", "Original", &[42]));
            fs::write(&path, &original).unwrap();
            if name == "database V2" {
                assert_eq!(
                    update_database_record(
                        path.clone(),
                        "Music/Other.mp3".into(),
                        metadata("Updated")
                    )
                    .unwrap(),
                    1
                );
                assert!(fs::read(&path).unwrap().starts_with(&protected));
                assert_eq!(
                    read_database_records(path.clone())
                        .unwrap()
                        .last()
                        .unwrap()
                        .artist
                        .as_deref(),
                    Some("Updated")
                );
                assert_eq!(
                    rewrite_database_path(
                        path.clone(),
                        "Music/Other.mp3".into(),
                        "Music/Renamed.mp3".into()
                    )
                    .unwrap(),
                    1
                );
                assert!(fs::read(&path).unwrap().starts_with(&protected));
                assert_eq!(
                    remove_track_from_database(path.clone(), "Music/Renamed.mp3".into()).unwrap(),
                    1
                );
                assert_eq!(fs::read(&path).unwrap(), protected);
                assert_eq!(
                    batch_add_tracks_to_database(
                        path.clone(),
                        vec![SeratoTrackAddition {
                            track_path: "Music/New.mp3".into(),
                            metadata: metadata("New"),
                        }]
                    )
                    .unwrap(),
                    1
                );
                assert!(fs::read(&path).unwrap().starts_with(&protected));
                let records = read_database_records(path.clone()).unwrap();
                assert_eq!(records.len(), 4);
                assert_eq!(records.last().unwrap().path, "Music/New.mp3");
            } else {
                assert_eq!(
                    rewrite_crate_path(
                        path.clone(),
                        "Music/Other.mp3".into(),
                        "Music/Renamed.mp3".into()
                    )
                    .unwrap(),
                    1
                );
                assert!(fs::read(&path).unwrap().starts_with(&protected));
                let paths = read_crate_paths(path.clone()).unwrap();
                assert_eq!(paths.len(), 4);
                assert_eq!(paths.last().unwrap(), "Music/Renamed.mp3");
                assert_eq!(
                    remove_path_from_crate(path.clone(), "Music/Renamed.mp3".into()).unwrap(),
                    1
                );
                assert_eq!(fs::read(&path).unwrap(), protected);
            }
        }
        fs::remove_dir_all(directory).unwrap();
    }
}
