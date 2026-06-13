use serde::{Deserialize, Serialize};

/// Desired output format for an entry. Feeds the ranker and the
/// auto-accept quality gate. Defaults to `Any`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum FormatPreference {
    Flac,
    /// Lossy, but at least 320 kbps.
    Lossy320Plus,
    #[default]
    Any,
}

/// One wanted track. A subset of crate-agent's track/placeholder schema
/// so the two are the same object at different lifecycle stages.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListEntry {
    pub artist: String,
    pub title: String,
    #[serde(default)]
    pub album: Option<String>,
    #[serde(default)]
    pub year: Option<u32>,
    #[serde(default)]
    pub duration_secs: Option<u64>,
    #[serde(default)]
    pub isrc: Option<String>,
    #[serde(default)]
    pub musicbrainz_recording_id: Option<String>,
    #[serde(default)]
    pub format_preference: FormatPreference,
}

/// One raw search result from slskd, normalized.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate {
    pub username: String,
    /// Remote path exactly as slskd reports it (often mangled:
    /// `01_-_artist_-_title_FINAL.mp3`).
    pub filename: String,
    pub size_bytes: u64,
    pub bitrate_kbps: Option<u32>,
    /// Lowercase extension without the dot: "flac", "mp3", "aiff".
    pub format: String,
    pub has_free_upload_slot: bool,
    pub length_secs: Option<u64>,
}

/// A candidate plus the ranker's verdict.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScoredCandidate {
    pub candidate: Candidate,
    pub score: i64,
    /// Human/Claude-readable notes on what helped or hurt the score.
    pub notes: Vec<String>,
}

/// Where a downloaded file came from. Recorded in the manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceInfo {
    pub slskd_username: String,
    pub original_filename: String,
    pub bitrate_kbps: Option<u32>,
    pub format: String,
    pub size_bytes: u64,
}

/// The staging-folder handoff contract — one per completed download.
/// `fingerprint` is the join key Phase 2 / crate-agent uses to match a
/// download to a waiting placeholder (by perceptual hash, NOT filename).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AcquisitionRecord {
    pub list_entry: ListEntry,
    pub file_path: String,
    pub fingerprint: Vec<u32>,
    pub source: SourceInfo,
    pub confirmed: bool,
}
