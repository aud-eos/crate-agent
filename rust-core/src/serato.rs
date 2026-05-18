// Serato library file reader/writer.
//
// The `.crate` files and the `database V2` file share the same TLV
// (tag-length-value) container format:
//
//     +--------+----------+----------------+
//     | tag    | length   | payload        |
//     | 4 ASCII| u32 BE   | `length` bytes |
//     +--------+----------+----------------+
//
// Top-level records of interest:
//   `vrsn`   version string (UTF-16BE)
//   `otrk`   track entry (container holding nested records)
//
// Within an `otrk` container the path tag differs by file type:
//   `.crate` files use `ptrk` (path-to-track)
//   `database V2` uses `pfil` (file path) and also stores rich metadata
//     under tags whose semantics are determined by the first character:
//       `o*` → struct (nested container)
//       `t*` → UTF-16BE string
//       `p*` → UTF-16BE string (semantically "path/identifier")
//       `u*` → unsigned 32-bit big-endian integer
//       `b*` → raw bytes
//
// SP-1 only needs to rewrite path entries (`ptrk` in `.crate`, `pfil`
// in `database V2`), so the rich-metadata interpretation rules are not
// implemented here — generic TLV parsing round-trips unknown tags
// byte-exact, so unknown metadata fields survive a rewrite untouched.
//
// Format references:
//   https://github.com/jesseward/Serato-lib   (SSL-Crate.txt — `.crate` layout)
//   https://github.com/flatmax/XwaxSeratoScanner   (SeratoData.py / Entry.py — `database V2` tag derivation rules)
//   https://github.com/Holzhaus/serato-tags   (per-track GEOB tags inside audio files — relevant to Pillar F)

use std::io::{Cursor, Read, Write};
use std::path::Path;

use thiserror::Error;

const TAG_OTRK: &[u8; 4] = b"otrk";
const TAG_PTRK: &[u8; 4] = b"ptrk";
const TAG_PFIL: &[u8; 4] = b"pfil";

#[derive(Debug, Error)]
pub enum SeratoError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("unexpected end of file at offset {offset} (needed {needed} bytes)")]
    UnexpectedEof { offset: u64, needed: usize },
    #[error("invalid UTF-16BE in `{tag}` field")]
    InvalidUtf16 { tag: String },
    #[error("invalid Serato file: {0}")]
    InvalidFile(String),
}

/// A single TLV record: 4-byte tag, 4-byte big-endian length, payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TlvRecord {
    pub tag: [u8; 4],
    pub payload: Vec<u8>,
}

impl TlvRecord {
    pub fn tag_str(&self) -> String {
        String::from_utf8_lossy(&self.tag).into_owned()
    }

    pub fn parse_all(bytes: &[u8]) -> Result<Vec<TlvRecord>, SeratoError> {
        let mut cursor = Cursor::new(bytes);
        let mut records = Vec::new();
        let total_len = bytes.len() as u64;

        while cursor.position() < total_len {
            let offset = cursor.position();

            let mut tag = [0u8; 4];
            cursor
                .read_exact(&mut tag)
                .map_err(|_| SeratoError::UnexpectedEof { offset, needed: 4 })?;

            let offset_after_tag = cursor.position();
            let mut length_bytes = [0u8; 4];
            cursor.read_exact(&mut length_bytes).map_err(|_| SeratoError::UnexpectedEof {
                offset: offset_after_tag,
                needed: 4,
            })?;
            let length = u32::from_be_bytes(length_bytes) as usize;

            let offset_after_length = cursor.position();
            let mut payload = vec![0u8; length];
            cursor.read_exact(&mut payload).map_err(|_| SeratoError::UnexpectedEof {
                offset: offset_after_length,
                needed: length,
            })?;

            records.push(TlvRecord { tag, payload });
        }

        Ok(records)
    }

    pub fn write_all<W: Write>(records: &[TlvRecord], writer: &mut W) -> Result<(), SeratoError> {
        for record in records {
            writer.write_all(&record.tag)?;
            let length = u32::try_from(record.payload.len()).map_err(|_| {
                SeratoError::InvalidFile(format!(
                    "payload for `{}` exceeds u32 length",
                    record.tag_str()
                ))
            })?;
            writer.write_all(&length.to_be_bytes())?;
            writer.write_all(&record.payload)?;
        }
        Ok(())
    }
}

fn decode_utf16be(bytes: &[u8]) -> Option<String> {
    if bytes.len() % 2 != 0 {
        return None;
    }
    let units: Vec<u16> =
        bytes.chunks_exact(2).map(|chunk| u16::from_be_bytes([chunk[0], chunk[1]])).collect();
    String::from_utf16(&units).ok()
}

fn encode_utf16be(value: &str) -> Vec<u8> {
    value.encode_utf16().flat_map(|unit| unit.to_be_bytes()).collect()
}

/// Extract a path from an `otrk` container payload by locating the
/// nested record whose tag matches `path_tag` and decoding its UTF-16BE
/// payload.
fn extract_path_from_otrk(otrk_payload: &[u8], path_tag: &[u8; 4]) -> Option<String> {
    let nested = TlvRecord::parse_all(otrk_payload).ok()?;
    let path_record = nested.iter().find(|record| record.tag == *path_tag)?;
    decode_utf16be(&path_record.payload)
}

/// Return every track path stored in `otrk` containers of the given
/// record list, keyed by the path tag (`ptrk` for `.crate`, `pfil` for
/// `database V2`).
fn track_paths_in_otrks(records: &[TlvRecord], path_tag: &[u8; 4]) -> Vec<String> {
    records
        .iter()
        .filter(|record| &record.tag == TAG_OTRK)
        .filter_map(|record| extract_path_from_otrk(&record.payload, path_tag))
        .collect()
}

/// Replace every `otrk` whose `path_tag` payload decodes to `old_path`
/// with one whose `path_tag` payload encodes `new_path`. Preserves all
/// other fields nested inside the `otrk` container byte-exact. Returns
/// the number of `otrk` records whose path was rewritten.
fn rewrite_path_in_otrks(
    records: &mut [TlvRecord],
    path_tag: &[u8; 4],
    old_path: &str,
    new_path: &str,
) -> usize {
    let mut count: usize = 0;
    for record in records.iter_mut() {
        if &record.tag != TAG_OTRK {
            continue;
        }
        let Ok(mut nested) = TlvRecord::parse_all(&record.payload) else {
            continue;
        };
        let mut changed = false;
        for nested_record in nested.iter_mut() {
            if nested_record.tag != *path_tag {
                continue;
            }
            let Some(current) = decode_utf16be(&nested_record.payload) else {
                continue;
            };
            if current == old_path {
                nested_record.payload = encode_utf16be(new_path);
                changed = true;
            }
        }
        if changed {
            let mut rebuilt = Vec::with_capacity(record.payload.len());
            TlvRecord::write_all(&nested, &mut rebuilt).expect("writing to Vec<u8> cannot fail");
            record.payload = rebuilt;
            count += 1;
        }
    }
    count
}

/// A parsed Serato `.crate` file. Records are kept in original order;
/// round-tripping (parse then re-serialize) is byte-exact for any file
/// whose every record obeys the TLV format.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CrateFile {
    pub records: Vec<TlvRecord>,
}

impl CrateFile {
    pub fn read_from_path(path: impl AsRef<Path>) -> Result<Self, SeratoError> {
        let bytes = std::fs::read(path.as_ref())?;
        Self::from_bytes(&bytes)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, SeratoError> {
        let records = TlvRecord::parse_all(bytes)?;
        Ok(CrateFile { records })
    }

    pub fn to_bytes(&self) -> Result<Vec<u8>, SeratoError> {
        let mut bytes = Vec::new();
        TlvRecord::write_all(&self.records, &mut bytes)?;
        Ok(bytes)
    }

    pub fn write_to_path(&self, path: impl AsRef<Path>) -> Result<(), SeratoError> {
        let bytes = self.to_bytes()?;
        std::fs::write(path.as_ref(), bytes)?;
        Ok(())
    }

    pub fn track_paths(&self) -> Vec<String> {
        track_paths_in_otrks(&self.records, TAG_PTRK)
    }

    pub fn rewrite_path(&mut self, old_path: &str, new_path: &str) -> usize {
        rewrite_path_in_otrks(&mut self.records, TAG_PTRK, old_path, new_path)
    }
}

/// A parsed Serato `database V2` file. Same TLV container format as a
/// `.crate` file but with `pfil` (file path) instead of `ptrk` and a
/// much richer per-track metadata payload inside each `otrk` (BPM,
/// artist, title, etc.). For SP-1 only the path field matters; other
/// fields are preserved byte-exact across a rewrite.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DatabaseV2 {
    pub records: Vec<TlvRecord>,
}

impl DatabaseV2 {
    pub fn read_from_path(path: impl AsRef<Path>) -> Result<Self, SeratoError> {
        let bytes = std::fs::read(path.as_ref())?;
        Self::from_bytes(&bytes)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, SeratoError> {
        let records = TlvRecord::parse_all(bytes)?;
        Ok(DatabaseV2 { records })
    }

    pub fn to_bytes(&self) -> Result<Vec<u8>, SeratoError> {
        let mut bytes = Vec::new();
        TlvRecord::write_all(&self.records, &mut bytes)?;
        Ok(bytes)
    }

    pub fn write_to_path(&self, path: impl AsRef<Path>) -> Result<(), SeratoError> {
        let bytes = self.to_bytes()?;
        std::fs::write(path.as_ref(), bytes)?;
        Ok(())
    }

    pub fn track_paths(&self) -> Vec<String> {
        track_paths_in_otrks(&self.records, TAG_PFIL)
    }

    pub fn rewrite_path(&mut self, old_path: &str, new_path: &str) -> usize {
        rewrite_path_in_otrks(&mut self.records, TAG_PFIL, old_path, new_path)
    }

    /// Number of `otrk` track entries in the database. Useful for
    /// progress reporting on full library scans.
    pub fn track_count(&self) -> usize {
        self.records.iter().filter(|record| &record.tag == TAG_OTRK).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_otrk(path_tag: &[u8; 4], path: &str) -> TlvRecord {
        let path_record = TlvRecord { tag: *path_tag, payload: encode_utf16be(path) };
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&[path_record], &mut otrk_payload).unwrap();
        TlvRecord { tag: *TAG_OTRK, payload: otrk_payload }
    }

    /// Build a synthetic library byte stream (works for either `.crate`
    /// or `database V2` depending on `path_tag`) containing the
    /// supplied version string and track paths.
    fn synthetic_library(version: &str, path_tag: &[u8; 4], paths: &[&str]) -> Vec<u8> {
        let mut records = vec![TlvRecord { tag: *b"vrsn", payload: encode_utf16be(version) }];
        for path in paths {
            records.push(synthetic_otrk(path_tag, path));
        }
        let mut bytes = Vec::new();
        TlvRecord::write_all(&records, &mut bytes).unwrap();
        bytes
    }

    // ===== CrateFile tests =====

    #[test]
    fn parses_synthetic_crate_and_returns_track_paths() {
        let bytes = synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &["Music/A/Artist - Track A.mp3", "Music/B/Artist - Track B.mp3"],
        );

        let parsed = CrateFile::from_bytes(&bytes).unwrap();
        assert_eq!(
            parsed.track_paths(),
            vec![
                "Music/A/Artist - Track A.mp3".to_string(),
                "Music/B/Artist - Track B.mp3".to_string(),
            ]
        );
    }

    #[test]
    fn crate_round_trips_byte_exact() {
        let bytes = synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &["Music/A/x.mp3", "Music/B/y.mp3"],
        );
        let parsed = CrateFile::from_bytes(&bytes).unwrap();
        let serialized = parsed.to_bytes().unwrap();
        assert_eq!(bytes, serialized, "round-trip must be byte-exact");
    }

    #[test]
    fn crate_rewrite_path_swaps_only_matching_track() {
        let mut parsed = CrateFile::from_bytes(&synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &["Music/A/old.mp3", "Music/B/keep.mp3", "Music/A/old.mp3"],
        ))
        .unwrap();

        let count = parsed.rewrite_path("Music/A/old.mp3", "Music/A/new.mp3");

        assert_eq!(count, 2, "should rewrite both occurrences of old.mp3");
        assert_eq!(
            parsed.track_paths(),
            vec![
                "Music/A/new.mp3".to_string(),
                "Music/B/keep.mp3".to_string(),
                "Music/A/new.mp3".to_string(),
            ]
        );
    }

    #[test]
    fn crate_rewrite_path_with_no_match_returns_zero_and_leaves_bytes_unchanged() {
        let bytes = synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &["Music/A/track.mp3"],
        );
        let mut parsed = CrateFile::from_bytes(&bytes).unwrap();

        let count = parsed.rewrite_path("Music/Z/does-not-exist.mp3", "Music/Z/new.mp3");

        assert_eq!(count, 0);
        assert_eq!(parsed.to_bytes().unwrap(), bytes);
    }

    #[test]
    fn crate_rewrite_path_preserves_other_nested_fields_in_otrk() {
        // Synthesize an otrk containing both a ptrk and an unknown tag.
        let ptrk = TlvRecord { tag: *TAG_PTRK, payload: encode_utf16be("Music/A/old.mp3") };
        let unknown = TlvRecord { tag: *b"zzzz", payload: vec![0xDE, 0xAD, 0xBE, 0xEF] };
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&[ptrk, unknown.clone()], &mut otrk_payload).unwrap();

        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("1.0/Serato ScratchLive Crate"),
        };
        let otrk = TlvRecord { tag: *TAG_OTRK, payload: otrk_payload };
        let mut crate_bytes = Vec::new();
        TlvRecord::write_all(&[vrsn, otrk], &mut crate_bytes).unwrap();

        let mut parsed = CrateFile::from_bytes(&crate_bytes).unwrap();
        let count = parsed.rewrite_path("Music/A/old.mp3", "Music/A/new.mp3");
        assert_eq!(count, 1);

        let rewritten_otrk = parsed
            .records
            .iter()
            .find(|record| &record.tag == TAG_OTRK)
            .expect("otrk record present");
        let nested = TlvRecord::parse_all(&rewritten_otrk.payload).unwrap();
        assert_eq!(nested.len(), 2);
        assert_eq!(&nested[0].tag, TAG_PTRK);
        assert_eq!(decode_utf16be(&nested[0].payload).unwrap(), "Music/A/new.mp3");
        assert_eq!(nested[1], unknown, "unknown nested record must be byte-identical");
    }

    #[test]
    fn parse_rejects_truncated_record() {
        // A `vrsn` tag claiming 10 bytes of payload but only 4 follow.
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"vrsn");
        bytes.extend_from_slice(&10u32.to_be_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 0]);
        assert!(matches!(
            CrateFile::from_bytes(&bytes),
            Err(SeratoError::UnexpectedEof { .. })
        ));
    }

    #[test]
    fn crate_write_to_and_read_from_disk() {
        let tmpdir = std::env::temp_dir().join("crate-agent-test-crate");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("Test.crate");

        let original = CrateFile::from_bytes(&synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &["Music/A/round.mp3"],
        ))
        .unwrap();

        original.write_to_path(&path).unwrap();
        let read_back = CrateFile::read_from_path(&path).unwrap();
        assert_eq!(read_back, original);

        std::fs::remove_file(&path).ok();
    }

    // ===== DatabaseV2 tests =====

    #[test]
    fn parses_synthetic_database_and_returns_track_paths() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Music/T/Track A.mp3", "Music/T/Track B.mp3"],
        );

        let parsed = DatabaseV2::from_bytes(&bytes).unwrap();
        assert_eq!(
            parsed.track_paths(),
            vec!["Music/T/Track A.mp3".to_string(), "Music/T/Track B.mp3".to_string()]
        );
        assert_eq!(parsed.track_count(), 2);
    }

    #[test]
    fn database_round_trips_byte_exact() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Music/A/x.mp3", "Music/B/y.mp3"],
        );
        let parsed = DatabaseV2::from_bytes(&bytes).unwrap();
        assert_eq!(parsed.to_bytes().unwrap(), bytes);
    }

    #[test]
    fn database_rewrite_path_preserves_other_metadata_in_otrk() {
        // Synthesize a realistic-ish otrk containing pfil + tart (artist)
        // + tsng (title) + tbpm (BPM) + a future unknown tag. Rewriting
        // pfil must not touch the metadata fields.
        let pfil = TlvRecord { tag: *TAG_PFIL, payload: encode_utf16be("Music/A/old.mp3") };
        let tart = TlvRecord { tag: *b"tart", payload: encode_utf16be("Some Artist") };
        let tsng = TlvRecord { tag: *b"tsng", payload: encode_utf16be("Some Track") };
        let tbpm = TlvRecord { tag: *b"tbpm", payload: encode_utf16be("128.000") };
        let unknown = TlvRecord { tag: *b"q9q9", payload: vec![1, 2, 3, 4, 5] };

        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(
            &[pfil, tart.clone(), tsng.clone(), tbpm.clone(), unknown.clone()],
            &mut otrk_payload,
        )
        .unwrap();

        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        };
        let otrk = TlvRecord { tag: *TAG_OTRK, payload: otrk_payload };
        let mut db_bytes = Vec::new();
        TlvRecord::write_all(&[vrsn, otrk], &mut db_bytes).unwrap();

        let mut parsed = DatabaseV2::from_bytes(&db_bytes).unwrap();
        let count = parsed.rewrite_path("Music/A/old.mp3", "Music/A/new.mp3");
        assert_eq!(count, 1);

        let rewritten_otrk = parsed
            .records
            .iter()
            .find(|record| &record.tag == TAG_OTRK)
            .expect("otrk present");
        let nested = TlvRecord::parse_all(&rewritten_otrk.payload).unwrap();
        assert_eq!(nested.len(), 5);
        assert_eq!(&nested[0].tag, TAG_PFIL);
        assert_eq!(decode_utf16be(&nested[0].payload).unwrap(), "Music/A/new.mp3");
        // Every metadata field after pfil must survive byte-identical.
        assert_eq!(nested[1], tart);
        assert_eq!(nested[2], tsng);
        assert_eq!(nested[3], tbpm);
        assert_eq!(nested[4], unknown);
    }

    #[test]
    fn database_track_count_matches_otrk_count() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["a.mp3", "b.mp3", "c.mp3", "d.mp3"],
        );
        let parsed = DatabaseV2::from_bytes(&bytes).unwrap();
        assert_eq!(parsed.track_count(), 4);
    }

    /// Opt-in integration test: parses a real Serato `database V2`
    /// file from disk if the env var points at one. Does not print
    /// any path content — only structural counts — so it is safe to
    /// run against real libraries.
    ///
    /// Run with:
    ///   CRATE_AGENT_TEST_DATABASE_V2="$HOME/Music/_Serato_/database V2" \
    ///     cargo test parses_real_database_v2 -- --nocapture
    #[test]
    fn parses_real_database_v2_when_env_var_set() {
        let Ok(path) = std::env::var("CRATE_AGENT_TEST_DATABASE_V2") else {
            eprintln!("CRATE_AGENT_TEST_DATABASE_V2 not set; skipping real-database test");
            return;
        };
        let database = DatabaseV2::read_from_path(&path)
            .expect("real database V2 must parse cleanly");
        let otrk_count = database.track_count();
        let path_count = database.track_paths().len();
        let file_size = std::fs::metadata(&path).unwrap().len();
        eprintln!(
            "real database V2: {} bytes, {} otrk records, {} pfil paths decoded",
            file_size, otrk_count, path_count
        );
        assert!(otrk_count > 0, "expected a non-empty database");
        assert_eq!(otrk_count, path_count, "every otrk should expose exactly one pfil");
        // Round-trip the bytes (parse → serialize) and confirm byte-exactness.
        let original_bytes = std::fs::read(&path).unwrap();
        let serialized = database.to_bytes().unwrap();
        assert_eq!(
            serialized.len(),
            original_bytes.len(),
            "parse → serialize must preserve file size"
        );
        assert!(
            serialized == original_bytes,
            "parse → serialize must be byte-exact for a real database file"
        );
    }
}
