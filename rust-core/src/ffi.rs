use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use thiserror::Error;

use crate::serato;
use crate::tags;
use fingerprint_core as fingerprint;

pub use crate::serato::{SeratoMetadataUpdate, SeratoRemovedRecord, SeratoTrackRecord};
pub use crate::serato_history::{SeratoHistoryPlay, SeratoHistoryScan};
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

/// What a Serato batch write did: how many records it changed, and which
/// requests matched no record, so a caller can tell a write that had nothing
/// to change from one whose track is not in the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeratoBatchWriteResult {
    pub rewritten_count: u32,
    /// Positions in the request list, in order.
    pub unmatched_indices: Vec<u32>,
}

impl SeratoBatchWriteResult {
    /// `held_paths` reports which of the `held_at` paths, one per request,
    /// a track is held at.
    fn new<'a>(
        count: usize,
        held_at: Vec<&'a str>,
        held_paths: impl FnOnce(Vec<&'a str>) -> HashSet<String>,
    ) -> Self {
        let held = held_paths(held_at.clone());
        Self {
            rewritten_count: u32::try_from(count).expect("rewrite count exceeded u32"),
            unmatched_indices: held_at
                .iter()
                .enumerate()
                .filter(|(_, path)| !held.contains(**path))
                .map(|(index, _)| u32::try_from(index).expect("request index exceeded u32"))
                .collect(),
        }
    }

    fn empty() -> Self {
        Self {
            rewritten_count: 0,
            unmatched_indices: Vec::new(),
        }
    }
}

/// Where each rename's record ends up: its new path, carried through every
/// later rename of that path. Read back to front, a record at a rename's old
/// path ends wherever one at its new path ends after it.
fn rename_destinations(renames: &[SeratoPathRename]) -> Vec<&str> {
    let mut final_paths: HashMap<&str, &str> = HashMap::new();
    let mut destinations = vec![""; renames.len()];
    for (index, rename) in renames.iter().enumerate().rev() {
        let destination = final_paths
            .get(rename.new_path.as_str())
            .copied()
            .unwrap_or(&rename.new_path);
        destinations[index] = destination;
        final_paths.insert(&rename.old_path, destination);
    }
    destinations
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
    #[error("{message}")]
    LandedNotDurable { message: String },
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
            landed @ serato::SeratoError::LandedNotDurable { .. } => CoreError::LandedNotDurable {
                message: landed.to_string(),
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
/// A rename matched when its record now sits at the chain's final path,
/// including one an earlier pass already moved there; a rename onto its
/// own path matched when that record exists.
pub fn batch_rewrite_database_paths(
    database_path: String,
    renames: Vec<SeratoPathRename>,
) -> Result<SeratoBatchWriteResult, CoreError> {
    if renames.is_empty() {
        return Ok(SeratoBatchWriteResult::empty());
    }
    let map = rename_map(&renames);
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let count = database.rewrite_paths(&map);
    if count > 0 {
        database.write_to_path(&path)?;
    }
    Ok(SeratoBatchWriteResult::new(
        count,
        rename_destinations(&renames),
        |paths| database.held_paths(paths),
    ))
}

/// Bulk variant of `rewrite_crate_path`. One file read + one file
/// write per crate file, regardless of how many renames apply within
/// that crate. Symmetric counterpart to `batch_rewrite_database_paths`.
/// Matching follows `batch_rewrite_database_paths`.
pub fn batch_rewrite_crate_paths(
    crate_path: String,
    renames: Vec<SeratoPathRename>,
) -> Result<SeratoBatchWriteResult, CoreError> {
    if renames.is_empty() {
        return Ok(SeratoBatchWriteResult::empty());
    }
    let map = rename_map(&renames);
    let path = PathBuf::from(crate_path);
    let mut crate_file = serato::CrateFile::read_from_path(&path)?;
    let count = crate_file.rewrite_paths(&map);
    if count > 0 {
        crate_file.write_to_path(&path)?;
    }
    Ok(SeratoBatchWriteResult::new(
        count,
        rename_destinations(&renames),
        |paths| crate_file.held_paths(paths),
    ))
}

pub fn remove_track_from_database(
    database_path: String,
    track_path: String,
) -> Result<u32, CoreError> {
    let removed = remove_track_from_database_capturing(database_path, track_path)?;
    Ok(u32::try_from(removed.len()).expect("remove count exceeded u32"))
}

pub fn remove_track_from_database_capturing(
    database_path: String,
    track_path: String,
) -> Result<Vec<SeratoRemovedRecord>, CoreError> {
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let removed = database.remove_track_capturing(&track_path)?;
    if !removed.is_empty() {
        database.write_to_path(&path)?;
    }
    Ok(removed)
}

pub fn remove_path_from_crate(crate_path: String, track_path: String) -> Result<u32, CoreError> {
    let removed = remove_path_from_crate_capturing(crate_path, track_path)?;
    Ok(u32::try_from(removed.len()).expect("remove count exceeded u32"))
}

pub fn remove_path_from_crate_capturing(
    crate_path: String,
    track_path: String,
) -> Result<Vec<SeratoRemovedRecord>, CoreError> {
    let path = PathBuf::from(crate_path);
    let mut crate_file = serato::CrateFile::read_from_path(&path)?;
    let removed = crate_file.remove_track_capturing(&track_path)?;
    if !removed.is_empty() {
        crate_file.write_to_path(&path)?;
    }
    Ok(removed)
}

/// Reinserts records captured by the `*_capturing` removals. The path tag
/// follows the file's extension: `.crate` and `.scrate` hold `ptrk`, anything
/// else is a database V2 holding `pfil`.
pub fn restore_removed_records(
    file_path: String,
    track_path: String,
    records: Vec<SeratoRemovedRecord>,
) -> Result<u32, CoreError> {
    let path = PathBuf::from(file_path);
    let is_crate_shaped = path
        .extension()
        .is_some_and(|extension| extension == "crate" || extension == "scrate");
    let restored = if is_crate_shaped {
        let mut crate_file = serato::CrateFile::read_from_path(&path)?;
        let restored = crate_file.restore_removed_records(&track_path, &records)?;
        if restored > 0 {
            crate_file.write_to_path(&path)?;
        }
        restored
    } else {
        let mut database = serato::DatabaseV2::read_from_path(&path)?;
        let restored = database.restore_removed_records(&track_path, &records)?;
        if restored > 0 {
            database.write_to_path(&path)?;
        }
        restored
    };
    Ok(u32::try_from(restored).expect("restore count exceeded u32"))
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

pub fn read_serato_history(history_directory: String) -> Result<SeratoHistoryScan, CoreError> {
    Ok(crate::serato_history::read_history(&PathBuf::from(
        history_directory,
    ))?)
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
) -> Result<SeratoBatchWriteResult, CoreError> {
    if updates.is_empty() {
        return Ok(SeratoBatchWriteResult::empty());
    }
    let path = PathBuf::from(database_path);
    let mut database = serato::DatabaseV2::read_from_path(&path)?;
    let requested: Vec<String> = updates
        .iter()
        .map(|entry| entry.track_path.clone())
        .collect();
    let map: HashMap<String, SeratoMetadataUpdate> = updates
        .into_iter()
        .map(|entry| (entry.track_path, entry.update))
        .collect();
    let count = database.batch_update_track_metadata(&map)?;
    if count > 0 {
        database.write_to_path(&path)?;
    }
    Ok(SeratoBatchWriteResult::new(
        count,
        requested.iter().map(String::as_str).collect(),
        |paths| database.held_paths(paths),
    ))
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedAudioDigest {
    pub pcm_sha256: Vec<u8>,
    pub format: String,
    pub sample_rate: u32,
    pub channel_count: u32,
    pub frame_count: u64,
    pub full_fingerprint_sha256: Vec<u8>,
}

pub fn decoded_audio_digest(file_path: String) -> Result<DecodedAudioDigest, CoreError> {
    let digest = fingerprint::decoded_audio_digest(PathBuf::from(file_path))?;
    Ok(DecodedAudioDigest {
        pcm_sha256: digest.pcm_sha256.to_vec(),
        format: digest.format,
        sample_rate: digest.sample_rate,
        channel_count: digest.channel_count,
        frame_count: digest.frame_count,
        full_fingerprint_sha256: digest.full_fingerprint_sha256.to_vec(),
    })
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
mod batch_write_result_tests {
    use super::*;
    use std::fs;

    fn library(paths: &[&str]) -> std::path::PathBuf {
        let mut bytes = Vec::new();
        let record = |tag: &[u8; 4], payload: &[u8]| {
            let mut encoded = tag.to_vec();
            encoded.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_be_bytes());
            encoded.extend_from_slice(payload);
            encoded
        };
        let text =
            |value: &str| -> Vec<u8> { value.encode_utf16().flat_map(u16::to_be_bytes).collect() };
        bytes.extend(record(b"vrsn", &text("2.0/Serato Scratch LIVE Database")));
        for path in paths {
            let pfil = record(b"pfil", &text(path));
            bytes.extend(record(b"otrk", &pfil));
        }
        let file = std::env::temp_dir().join(format!(
            "crate-batch-result-{}-{}",
            std::process::id(),
            paths.join("+").replace('/', "_")
        ));
        fs::write(&file, bytes).unwrap();
        file
    }

    fn rename(old_path: &str, new_path: &str) -> SeratoPathRename {
        SeratoPathRename {
            old_path: old_path.into(),
            new_path: new_path.into(),
        }
    }

    #[test]
    fn renames_report_only_those_whose_track_is_not_at_its_final_path() {
        let rewrite = |held: &[&str], renames: Vec<SeratoPathRename>| {
            let file = library(held);
            let result =
                batch_rewrite_database_paths(file.to_str().unwrap().into(), renames).unwrap();
            fs::remove_file(&file).unwrap();
            (result.rewritten_count, result.unmatched_indices)
        };
        let chains_and_cycles = vec![
            rename("Music/A.mp3", "Music/B.mp3"),
            rename("Music/B.mp3", "Music/C.mp3"),
            rename("Music/Earlier.mp3", "Music/Moved.mp3"),
            rename("Music/Gone.mp3", "Music/Nowhere.mp3"),
            rename("Music/Loop.mp3", "Music/Away.mp3"),
            rename("Music/Away.mp3", "Music/Loop.mp3"),
            rename("Music/Back.mp3", "Music/Forth.mp3"),
            rename("Music/Forth.mp3", "Music/Back.mp3"),
            rename("Music/Back.mp3", "Music/Forth.mp3"),
        ];
        assert_eq!(
            rewrite(
                &[
                    "Music/A.mp3",
                    "Music/Moved.mp3",
                    "Music/Loop.mp3",
                    "Music/Back.mp3"
                ],
                chains_and_cycles
            ),
            (2, vec![3])
        );

        let reused_old_path = || {
            vec![
                rename("Music/A.mp3", "Music/B.mp3"),
                rename("Music/X.mp3", "Music/A.mp3"),
                rename("Music/A.mp3", "Music/C.mp3"),
            ]
        };
        assert_eq!(rewrite(&["Music/X.mp3"], reused_old_path()).1, vec![0]);
        assert_eq!(rewrite(&["Music/A.mp3"], reused_old_path()).1, vec![1, 2]);
    }
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
            year: None,
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
