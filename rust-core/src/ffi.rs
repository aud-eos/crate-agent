use std::path::PathBuf;

use thiserror::Error;

use crate::fingerprint;
use crate::serato;
use crate::tags;

pub use crate::serato::SeratoTrackRecord;
pub use crate::tags::AudioTags;

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
        CoreError::IoError { message: err.to_string() }
    }
}

impl From<serato::SeratoError> for CoreError {
    fn from(err: serato::SeratoError) -> Self {
        match err {
            serato::SeratoError::Io(io_err) => {
                CoreError::IoError { message: io_err.to_string() }
            }
            other => CoreError::SeratoFormat { message: other.to_string() },
        }
    }
}

impl From<fingerprint::FingerprintError> for CoreError {
    fn from(err: fingerprint::FingerprintError) -> Self {
        match err {
            fingerprint::FingerprintError::Io(io_err) => {
                CoreError::IoError { message: io_err.to_string() }
            }
            other => CoreError::Fingerprint { message: other.to_string() },
        }
    }
}

impl From<tags::TagError> for CoreError {
    fn from(err: tags::TagError) -> Self {
        match err {
            tags::TagError::Io(io_err) => CoreError::IoError { message: io_err.to_string() },
            other => CoreError::Tag { message: other.to_string() },
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

pub fn fingerprint_audio_file(file_path: String) -> Result<Vec<u32>, CoreError> {
    let path = PathBuf::from(file_path);
    Ok(fingerprint::fingerprint_file(&path)?)
}

pub fn read_audio_tags(file_path: String) -> Result<AudioTags, CoreError> {
    let path = PathBuf::from(file_path);
    Ok(tags::read_tags(&path)?)
}
