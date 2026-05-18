// Serato `.crate` file reader/writer.
//
// `.crate` files use a TLV (tag-length-value) container format. Each
// record is:
//
//     +--------+----------+----------------+
//     | tag    | length   | payload        |
//     | 4 ASCII| u32 BE   | `length` bytes |
//     +--------+----------+----------------+
//
// Top-level records relevant to SP-1:
//   `vrsn`   version string (UTF-16BE)
//   `otrk`   track entry (container holding nested records)
//     `ptrk` track path (UTF-16BE)   — the field SP-1 rewrites
//
// Other top-level records (`osrt`, `ovct`, etc. — sort and column
// configuration) are preserved byte-exact through round-tripping
// because we re-emit each record from its parsed tag + payload.
//
// Format documentation references:
//   https://github.com/jesseward/Serato-lib (SSL-Crate.txt)
//   https://github.com/Holzhaus/serato-tags (per-track GEOB tags;
//   relevant for Pillar F, not SP-1)

use std::io::{Cursor, Read, Write};
use std::path::Path;

use thiserror::Error;

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

    /// Return every track path stored in `otrk → ptrk` entries.
    pub fn track_paths(&self) -> Vec<String> {
        self.records
            .iter()
            .filter(|record| &record.tag == b"otrk")
            .filter_map(|record| extract_track_path(&record.payload))
            .collect()
    }

    /// Replace every `otrk` whose `ptrk` payload decodes to `old_path`
    /// with one whose `ptrk` payload encodes `new_path`. Preserves all
    /// other fields nested inside the `otrk` container. Returns the
    /// number of replacements made.
    pub fn rewrite_path(&mut self, old_path: &str, new_path: &str) -> usize {
        let mut count: usize = 0;
        for record in self.records.iter_mut() {
            if &record.tag != b"otrk" {
                continue;
            }
            let Ok(mut nested) = TlvRecord::parse_all(&record.payload) else {
                continue;
            };
            let mut changed = false;
            for nested_record in nested.iter_mut() {
                if &nested_record.tag != b"ptrk" {
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
                TlvRecord::write_all(&nested, &mut rebuilt)
                    .expect("writing to Vec<u8> cannot fail");
                record.payload = rebuilt;
                count += 1;
            }
        }
        count
    }
}

fn extract_track_path(otrk_payload: &[u8]) -> Option<String> {
    let nested = TlvRecord::parse_all(otrk_payload).ok()?;
    let ptrk = nested.iter().find(|record| &record.tag == b"ptrk")?;
    decode_utf16be(&ptrk.payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a synthetic `.crate` byte stream containing the supplied
    /// version string and track paths, suitable for round-trip and
    /// rewrite testing.
    fn synthetic_crate(version: &str, paths: &[&str]) -> Vec<u8> {
        let vrsn_record =
            TlvRecord { tag: *b"vrsn", payload: encode_utf16be(version) };

        let mut records = vec![vrsn_record];
        for path in paths {
            let ptrk = TlvRecord { tag: *b"ptrk", payload: encode_utf16be(path) };
            let mut otrk_payload = Vec::new();
            TlvRecord::write_all(&[ptrk], &mut otrk_payload).unwrap();
            records.push(TlvRecord { tag: *b"otrk", payload: otrk_payload });
        }

        let mut bytes = Vec::new();
        TlvRecord::write_all(&records, &mut bytes).unwrap();
        bytes
    }

    #[test]
    fn parses_synthetic_crate_and_returns_track_paths() {
        let bytes = synthetic_crate(
            "1.0/Serato ScratchLive Crate",
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
    fn round_trips_byte_exact() {
        let bytes = synthetic_crate(
            "1.0/Serato ScratchLive Crate",
            &["Music/A/x.mp3", "Music/B/y.mp3"],
        );
        let parsed = CrateFile::from_bytes(&bytes).unwrap();
        let serialized = parsed.to_bytes().unwrap();
        assert_eq!(bytes, serialized, "round-trip must be byte-exact");
    }

    #[test]
    fn rewrite_path_swaps_only_matching_track() {
        let mut parsed = CrateFile::from_bytes(&synthetic_crate(
            "1.0/Serato ScratchLive Crate",
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
    fn rewrite_path_with_no_match_returns_zero_and_leaves_bytes_unchanged() {
        let bytes = synthetic_crate(
            "1.0/Serato ScratchLive Crate",
            &["Music/A/track.mp3"],
        );
        let mut parsed = CrateFile::from_bytes(&bytes).unwrap();

        let count = parsed.rewrite_path("Music/Z/does-not-exist.mp3", "Music/Z/new.mp3");

        assert_eq!(count, 0);
        assert_eq!(parsed.to_bytes().unwrap(), bytes);
    }

    #[test]
    fn rewrite_path_preserves_other_nested_fields_in_otrk() {
        // Synthesize an otrk containing both a ptrk and an unknown tag
        // (`zzzz` with arbitrary payload). Rewriting ptrk must not
        // touch the unknown tag.
        let ptrk = TlvRecord { tag: *b"ptrk", payload: encode_utf16be("Music/A/old.mp3") };
        let unknown = TlvRecord { tag: *b"zzzz", payload: vec![0xDE, 0xAD, 0xBE, 0xEF] };
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&[ptrk, unknown.clone()], &mut otrk_payload).unwrap();

        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("1.0/Serato ScratchLive Crate"),
        };
        let otrk = TlvRecord { tag: *b"otrk", payload: otrk_payload };
        let mut crate_bytes = Vec::new();
        TlvRecord::write_all(&[vrsn, otrk], &mut crate_bytes).unwrap();

        let mut parsed = CrateFile::from_bytes(&crate_bytes).unwrap();
        let count = parsed.rewrite_path("Music/A/old.mp3", "Music/A/new.mp3");
        assert_eq!(count, 1);

        // Re-parse the rewritten otrk to confirm the unknown record survived.
        let rewritten_otrk = parsed
            .records
            .iter()
            .find(|record| &record.tag == b"otrk")
            .expect("otrk record present");
        let nested = TlvRecord::parse_all(&rewritten_otrk.payload).unwrap();
        assert_eq!(nested.len(), 2);
        assert_eq!(&nested[0].tag, b"ptrk");
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
    fn write_to_and_read_from_disk() {
        let tmpdir = std::env::temp_dir().join("crate-agent-test-crate");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("Test.crate");

        let original = CrateFile::from_bytes(&synthetic_crate(
            "1.0/Serato ScratchLive Crate",
            &["Music/A/round.mp3"],
        ))
        .unwrap();

        original.write_to_path(&path).unwrap();
        let read_back = CrateFile::read_from_path(&path).unwrap();
        assert_eq!(read_back, original);

        std::fs::remove_file(&path).ok();
    }
}
