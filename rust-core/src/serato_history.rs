//! Reads Serato's play history (`_Serato_/History/Sessions/*.session`).
//!
//! A session file is a TLV stream: one `vrsn` record, then one `oent`
//! record per deck load. Each `oent` holds a single `adat` record whose
//! payload is a list of fields shaped like TLV records but keyed by a
//! big-endian `u32` field id instead of a 4-byte tag. Field ids follow
//! the community-documented layout (see tombell/go-serato).
//!
//! The reader is strict: anything it does not recognise is an error that
//! names the session file, never a silently skipped entry. Read-only.

use std::path::Path;

use crate::serato::{decode_utf16be, SeratoError, TlvRecord};

/// The only session format this reader has been verified against.
const SUPPORTED_VERSION: &str = "1.0/Serato Scratch LIVE Review";
const FIELD_FULL_PATH: u32 = 2;
const FIELD_START_TIME: u32 = 28;
const FIELD_PLAYED: u32 = 50;

/// One deck load that Serato marked as played.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeratoHistoryPlay {
    /// The absolute path as Serato recorded it at play time.
    pub path: String,
    /// Seconds since the Unix epoch.
    pub started_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeratoHistoryScan {
    pub plays: Vec<SeratoHistoryPlay>,
    pub session_count: u32,
    /// Deck loads Serato did not mark as played.
    pub unplayed_count: u32,
    /// Played entries that are not files, such as streaming tracks
    /// (`_783160.beatsource`). Skipped by rule: only absolute paths count.
    pub non_file_count: u32,
}

/// Reads every `Sessions/*.session` file under `history_directory`. A
/// library that has never been played has no `Sessions` directory and
/// yields an empty scan.
pub fn read_history(history_directory: &Path) -> Result<SeratoHistoryScan, SeratoError> {
    let mut scan = SeratoHistoryScan {
        plays: Vec::new(),
        session_count: 0,
        unplayed_count: 0,
        non_file_count: 0,
    };
    let sessions_directory = history_directory.join("Sessions");
    let entries = match std::fs::read_dir(&sessions_directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(scan),
        Err(error) => return Err(error.into()),
    };
    let mut session_paths = Vec::new();
    for entry in entries {
        let path = entry?.path();
        if path
            .extension()
            .is_some_and(|extension| extension == "session")
        {
            session_paths.push(path);
        }
    }
    session_paths.sort();
    for session_path in session_paths {
        let name = session_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let bytes = std::fs::read(&session_path).map_err(|error| {
            SeratoError::Io(std::io::Error::new(
                error.kind(),
                format!("History session {name}: {error}"),
            ))
        })?;
        read_session(&bytes, &mut scan).map_err(|error| {
            SeratoError::InvalidFile(format!("History session {name}: {error}"))
        })?;
        scan.session_count += 1;
    }
    Ok(scan)
}

fn read_session(bytes: &[u8], scan: &mut SeratoHistoryScan) -> Result<(), SeratoError> {
    let records = TlvRecord::parse_all(bytes)?;
    let (version, entries) = records
        .split_first()
        .ok_or_else(|| SeratoError::InvalidFile("empty session".into()))?;
    if version.tag != *b"vrsn" {
        return Err(SeratoError::InvalidFile(
            "session does not start with vrsn".into(),
        ));
    }
    let version_text = decode_utf16be(&version.payload)
        .ok_or_else(|| SeratoError::InvalidUtf16 { tag: "vrsn".into() })?;
    if version_text != SUPPORTED_VERSION {
        return Err(SeratoError::InvalidFile(format!(
            "unsupported session version {version_text:?}"
        )));
    }
    for entry in entries {
        if entry.tag != *b"oent" {
            return Err(SeratoError::InvalidFile(format!(
                "unexpected `{}` record",
                entry.tag_str()
            )));
        }
        let nested = TlvRecord::parse_all(&entry.payload)?;
        let [data] = nested.as_slice() else {
            return Err(SeratoError::InvalidFile(
                "oent must hold exactly one adat".into(),
            ));
        };
        if data.tag != *b"adat" {
            return Err(SeratoError::InvalidFile(format!(
                "unexpected `{}` record in oent",
                data.tag_str()
            )));
        }
        read_entry(&TlvRecord::parse_all(&data.payload)?, scan)?;
    }
    Ok(())
}

fn read_entry(fields: &[TlvRecord], scan: &mut SeratoHistoryScan) -> Result<(), SeratoError> {
    let field = |identifier: u32| {
        let mut matches = fields
            .iter()
            .filter(move |field| u32::from_be_bytes(field.tag) == identifier);
        let first = matches.next();
        if matches.next().is_some() {
            return Err(SeratoError::InvalidFile(format!(
                "entry repeats field {identifier}"
            )));
        }
        Ok(first)
    };
    let played = match field(FIELD_PLAYED)?.map(|field| field.payload.as_slice()) {
        Some([0]) => false,
        Some([1]) => true,
        Some(_) => return Err(SeratoError::InvalidFile("played flag is not 0 or 1".into())),
        None => return Err(SeratoError::InvalidFile("entry has no played flag".into())),
    };
    if !played {
        scan.unplayed_count += 1;
        return Ok(());
    }
    let path_field = field(FIELD_FULL_PATH)?
        .ok_or_else(|| SeratoError::InvalidFile("played entry has no path".into()))?;
    let decoded = decode_utf16be(&path_field.payload).ok_or_else(|| SeratoError::InvalidUtf16 {
        tag: "full path".into(),
    })?;
    let path = decoded.strip_suffix('\0').unwrap_or(&decoded);
    if path.is_empty() || path.contains('\0') {
        return Err(SeratoError::InvalidFile(
            "played entry has an empty or NUL-containing path".into(),
        ));
    }
    let started_at = match field(FIELD_START_TIME)?.map(|field| field.payload.as_slice()) {
        Some(&[first, second, third, fourth]) => u32::from_be_bytes([first, second, third, fourth]),
        _ => {
            return Err(SeratoError::InvalidFile(
                "played entry has no 4-byte start time".into(),
            ))
        }
    };
    if !path.starts_with('/') {
        scan.non_file_count += 1;
        return Ok(());
    }
    scan.plays.push(SeratoHistoryPlay {
        path: path.to_string(),
        started_at: u64::from(started_at),
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const VERSION: &str = "1.0/Serato Scratch LIVE Review";

    fn record(tag: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut bytes = tag.to_vec();
        bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        bytes.extend_from_slice(payload);
        bytes
    }

    fn field(identifier: u32, payload: &[u8]) -> Vec<u8> {
        record(&identifier.to_be_bytes(), payload)
    }

    fn utf16(value: &str) -> Vec<u8> {
        value
            .encode_utf16()
            .chain([0])
            .flat_map(|unit| unit.to_be_bytes())
            .collect()
    }

    fn entry(path: &str, played: bool, started_at: u32) -> Vec<u8> {
        let mut fields = field(1, &7u32.to_be_bytes());
        fields.extend(field(2, &utf16(path)));
        fields.extend(field(28, &started_at.to_be_bytes()));
        fields.extend(field(50, &[u8::from(played)]));
        record(b"oent", &record(b"adat", &fields))
    }

    fn session(entries: &[Vec<u8>]) -> Vec<u8> {
        let without_terminator: Vec<u8> = VERSION
            .encode_utf16()
            .flat_map(|unit| unit.to_be_bytes())
            .collect();
        let mut bytes = record(b"vrsn", &without_terminator);
        for entry in entries {
            bytes.extend_from_slice(entry);
        }
        bytes
    }

    fn history(sessions: &[(&str, Vec<u8>)]) -> tempfile::TempDir {
        let directory = tempfile::tempdir().expect("temporary directory");
        let sessions_directory = directory.path().join("Sessions");
        std::fs::create_dir(&sessions_directory).expect("Sessions directory");
        for (name, bytes) in sessions {
            std::fs::write(sessions_directory.join(name), bytes).expect("session file");
        }
        directory
    }

    #[test]
    fn counts_only_played_file_entries_across_sessions() {
        let directory = history(&[
            (
                "1.session",
                session(&[
                    entry("/Music/A/Artist - Song.mp3", true, 1_600_000_000),
                    entry("/Music/A/Artist - Song.mp3", false, 1_600_000_100),
                    entry("_783160.beatsource", true, 1_600_000_200),
                ]),
            ),
            (
                "2.session",
                session(&[entry(
                    "/Volumes/Drive/B/Band - Tune.flac",
                    true,
                    1_700_000_000,
                )]),
            ),
            ("notes.txt", b"not a session".to_vec()),
        ]);

        let scan = read_history(directory.path()).expect("synthetic history parses");
        let mut plays: Vec<(String, u64)> = scan
            .plays
            .into_iter()
            .map(|play| (play.path, play.started_at))
            .collect();
        plays.sort();
        assert_eq!(
            plays,
            vec![
                ("/Music/A/Artist - Song.mp3".to_string(), 1_600_000_000),
                (
                    "/Volumes/Drive/B/Band - Tune.flac".to_string(),
                    1_700_000_000
                ),
            ]
        );
        assert_eq!(scan.session_count, 2);
        assert_eq!(
            scan.unplayed_count, 1,
            "loaded-but-not-played entries are counted separately"
        );
        assert_eq!(
            scan.non_file_count, 1,
            "streaming entries are skipped by rule and counted"
        );
    }

    #[test]
    fn corrupt_or_unrecognised_sessions_fail_with_the_session_name() {
        let mut truncated = session(&[entry("/Music/A/Song.mp3", true, 1)]);
        truncated.truncate(truncated.len() - 3);
        let mut unknown_record = session(&[]);
        unknown_record.extend(record(b"oren", b""));
        let mut missing_played_flag = session(&[]);
        missing_played_flag.extend(record(
            b"oent",
            &record(b"adat", &field(2, &utf16("/Music/A/Song.mp3"))),
        ));
        let mut wrong_version = record(b"vrsn", &utf16("2.0/Serato Something Else"));
        wrong_version.extend(entry("/Music/A/Song.mp3", true, 1));

        for (name, bytes) in [
            ("truncated.session", truncated),
            ("unknown.session", unknown_record),
            ("unflagged.session", missing_played_flag),
            ("version.session", wrong_version),
        ] {
            let directory = history(&[(name, bytes)]);
            let error = read_history(directory.path())
                .err()
                .unwrap_or_else(|| panic!("{name} must be rejected"));
            assert!(error.to_string().contains(name), "{name}: {error}");
        }
    }

    #[test]
    fn a_library_without_history_has_no_plays() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let scan = read_history(directory.path()).expect("missing Sessions is an empty history");
        assert!(scan.plays.is_empty());
        assert_eq!(scan.session_count, 0);
    }
}
