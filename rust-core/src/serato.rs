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

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Cursor, ErrorKind, Read, Write};
use std::path::{Path, PathBuf};

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
    /// The new bytes replaced the file, but its directory could not be
    /// flushed, so the rename may not survive a power loss. The write landed.
    #[error("{path} was replaced but may not be durable: {source}")]
    LandedNotDurable {
        path: String,
        source: std::io::Error,
    },
}

/// Replaces `path` with what `write` produces, all or nothing: the bytes go
/// to a temporary file in the same directory, which is flushed to disk and
/// then renamed over the target. A failure before the rename leaves the
/// target's previous bytes in place, so a thrown write never landed. The
/// target keeps its permissions; a symlinked target is replaced at the file
/// it points to. A failure to flush the directory after the rename is
/// `LandedNotDurable`, since the new bytes are already in place.
fn replace_file(
    path: &Path,
    write: impl FnOnce(&mut File) -> std::io::Result<()>,
) -> Result<(), SeratoError> {
    let target = match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => fs::canonicalize(path)?,
        Ok(_) => path.to_path_buf(),
        Err(error) if error.kind() == ErrorKind::NotFound => path.to_path_buf(),
        Err(error) => return Err(error.into()),
    };
    let directory = match target.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => PathBuf::from("."),
    };
    remove_stale_temporary_files(&directory)?;
    let mut temporary = tempfile::Builder::new()
        .prefix(TEMPORARY_PREFIX)
        .suffix(TEMPORARY_SUFFIX)
        .tempfile_in(&directory)?;
    match fs::metadata(&target) {
        Ok(metadata) => temporary
            .as_file()
            .set_permissions(metadata.permissions())?,
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    write(temporary.as_file_mut())?;
    temporary.as_file().sync_all()?;
    temporary.persist(&target).map_err(|error| error.error)?;
    File::open(&directory)
        .and_then(|handle| handle.sync_all())
        .map_err(|source| SeratoError::LandedNotDurable {
            path: target.display().to_string(),
            source,
        })
}

const TEMPORARY_PREFIX: &str = ".crate-agent-";
const TEMPORARY_SUFFIX: &str = ".tmp";

/// Removes temporary files a crashed rewrite left in `directory`. Writes to
/// one library are serialized, so none of these belongs to a live write.
fn remove_stale_temporary_files(directory: &Path) -> std::io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.len() > TEMPORARY_PREFIX.len() + TEMPORARY_SUFFIX.len()
            && name.starts_with(TEMPORARY_PREFIX)
            && name.ends_with(TEMPORARY_SUFFIX)
            && entry.file_type()?.is_file()
        {
            fs::remove_file(entry.path())?;
        }
    }
    Ok(())
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
            cursor
                .read_exact(&mut length_bytes)
                .map_err(|_| SeratoError::UnexpectedEof {
                    offset: offset_after_tag,
                    needed: 4,
                })?;
            let length = u32::from_be_bytes(length_bytes) as usize;

            let offset_after_length = cursor.position();
            if length as u64 > total_len - offset_after_length {
                return Err(SeratoError::UnexpectedEof {
                    offset: offset_after_length,
                    needed: length,
                });
            }
            let mut payload = vec![0u8; length];
            cursor
                .read_exact(&mut payload)
                .map_err(|_| SeratoError::UnexpectedEof {
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
    let (code_unit_pairs, remainder) = bytes.as_chunks::<2>();
    if !remainder.is_empty() {
        return None;
    }
    // Stream the u16 units through char::decode_utf16 directly into
    // a String — no intermediate Vec<u16>. `read_database_records`
    // calls this up to 10× per otrk; a 20k-track read previously
    // allocated 200k transient vectors.
    char::decode_utf16(
        code_unit_pairs
            .iter()
            .map(|code_unit_pair| u16::from_be_bytes(*code_unit_pair)),
    )
    .collect::<Result<String, _>>()
    .ok()
}

fn encode_utf16be(value: &str) -> Vec<u8> {
    // UTF-8 byte length is a tight upper bound for the UTF-16 byte
    // length on Western text (1 byte ASCII → 2 bytes UTF-16) and
    // safe for higher planes (4-byte UTF-8 emoji → 4 bytes UTF-16).
    // Skips the doubling-reallocation chain that `flat_map`'s
    // unsized size_hint forced on every call.
    let mut out = Vec::with_capacity(value.len() * 2);
    for unit in value.encode_utf16() {
        out.extend_from_slice(&unit.to_be_bytes());
    }
    out
}

/// Extract a path from an `otrk` container payload by locating the
/// nested record whose tag matches `path_tag` and decoding its UTF-16BE
/// payload.
fn extract_path_from_otrk(otrk_payload: &[u8], path_tag: &[u8; 4]) -> Option<String> {
    let nested = TlvRecord::parse_all(otrk_payload).ok()?;
    let path_record = nested.iter().find(|record| record.tag == *path_tag)?;
    decode_utf16be(&path_record.payload)
}

/// Extract a full `SeratoTrackRecord` from an `otrk` container's
/// payload. Returns `None` if the container has no `pfil` (path)
/// field — an entry without a path can't be matched to a file on
/// disk and has nothing useful to expose.
///
/// Other fields decode each on a best-effort basis: if a `t*` tag is
/// present but its UTF-16BE payload is malformed, that field stays
/// `None` and the rest of the record is still returned. Unknown
/// tags inside the `otrk` (and Serato's database has many) are
/// intentionally ignored — adding more tag mappings is incremental.
fn extract_track_record(otrk_payload: &[u8]) -> Option<SeratoTrackRecord> {
    let nested = TlvRecord::parse_all(otrk_payload).ok()?;

    let path = nested
        .iter()
        .find(|record| &record.tag == TAG_PFIL)
        .and_then(|record| decode_utf16be(&record.payload))?;

    Some(decode_track_fields(&nested, path))
}

fn decode_track_fields(nested: &[TlvRecord], path: String) -> SeratoTrackRecord {
    let mut track = SeratoTrackRecord {
        path,
        artist: None,
        title: None,
        album: None,
        genre: None,
        bpm: None,
        key: None,
        comment: None,
        length: None,
        label: None,
    };

    for field in nested {
        match &field.tag {
            b"tart" => track.artist = decode_utf16be(&field.payload),
            b"tsng" => track.title = decode_utf16be(&field.payload),
            b"talb" => track.album = decode_utf16be(&field.payload),
            b"tgen" => track.genre = decode_utf16be(&field.payload),
            b"tbpm" => track.bpm = decode_utf16be(&field.payload),
            b"tkey" => track.key = decode_utf16be(&field.payload),
            b"tcom" => track.comment = decode_utf16be(&field.payload),
            b"tlen" => track.length = decode_utf16be(&field.payload),
            b"tlbl" => track.label = decode_utf16be(&field.payload),
            _ => {}
        }
    }

    track
}

/// Full per-track metadata extracted from a Serato `database V2`
/// entry. `path` is required; all other fields are present when the
/// corresponding `t*` tag exists in the `otrk` container and decodes
/// as valid UTF-16BE.
///
/// The text fields (`bpm`, `key`, `length`, `label`) are returned as
/// strings rather than parsed numerics. Serato stores BPM as
/// `"128.000"`, length as `"03:24"`, etc. — preserving the source
/// representation keeps the FFI surface lossless; callers parse as
/// they see fit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeratoTrackRecord {
    pub path: String,
    pub artist: Option<String>,
    pub title: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub bpm: Option<String>,
    pub key: Option<String>,
    pub comment: Option<String>,
    pub length: Option<String>,
    pub label: Option<String>,
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

/// Walks an `otrk` payload's nested TLV headers in place, without
/// allocating, and reports whether any `path_tag` field's raw payload is
/// one of `encoded_paths`. UTF-16 encoding is unique, so matching the
/// encoded bytes is exactly equivalent to decoding and comparing strings.
/// The walk follows real field boundaries: target bytes inside another
/// field's payload, or straddling two fields, never match. A `true`
/// result is only a candidate — callers still full-parse it, so an otrk
/// with a malformed tail keeps its unparseable-otrk handling.
fn otrk_has_path_in(
    otrk_payload: &[u8],
    path_tag: &[u8; 4],
    encoded_paths: &HashSet<Vec<u8>>,
) -> bool {
    let mut found = false;
    walk_nested_fields(otrk_payload, |tag, payload| {
        if tag == path_tag && encoded_paths.contains(payload) {
            found = true;
        }
    });
    found
}

/// The path an `otrk` is keyed by: its first `path_tag` field that decodes.
fn first_decodable_path(nested: &[TlvRecord], path_tag: &[u8; 4]) -> Option<String> {
    nested
        .iter()
        .filter(|field| &field.tag == path_tag)
        .find_map(|field| decode_utf16be(&field.payload))
}

/// Which of `paths` some `otrk` is keyed by, under the metadata writer's
/// rule (`first_decodable_path` of a well-formed record). Only records
/// holding a requested path are parsed.
fn held_paths_in_otrks<'path>(
    records: &[TlvRecord],
    path_tag: &[u8; 4],
    paths: impl IntoIterator<Item = &'path str>,
) -> HashSet<String> {
    let encoded_paths: HashSet<Vec<u8>> = paths.into_iter().map(encode_utf16be).collect();
    records
        .iter()
        .filter(|record| {
            &record.tag == TAG_OTRK && otrk_has_path_in(&record.payload, path_tag, &encoded_paths)
        })
        .filter_map(|record| TlvRecord::parse_all(&record.payload).ok())
        .filter_map(|nested| first_decodable_path(&nested, path_tag))
        .filter(|path| encoded_paths.contains(&encode_utf16be(path)))
        .collect()
}

/// Visits each well-formed nested field in order and returns whether the
/// whole payload parsed cleanly — the same acceptance as
/// `TlvRecord::parse_all`.
fn walk_nested_fields<'payload>(
    payload: &'payload [u8],
    mut visit: impl FnMut(&[u8; 4], &'payload [u8]),
) -> bool {
    let mut offset = 0;
    while offset < payload.len() {
        let Some(header) = payload.get(offset..offset + 8) else {
            return false;
        };
        let tag: &[u8; 4] = header[..4].try_into().expect("header holds a 4-byte tag");
        let length = u32::from_be_bytes(
            header[4..]
                .try_into()
                .expect("header holds a 4-byte length"),
        ) as usize;
        let start = offset + 8;
        let Some(field) = start
            .checked_add(length)
            .and_then(|end| payload.get(start..end))
        else {
            return false;
        };
        visit(tag, field);
        offset = start + length;
    }
    true
}

/// Drop every top-level `otrk` whose path field (`pfil` for
/// database V2, `ptrk` for `.crate`) matches `target_path`.
/// Non-otrk records and otrks pointing elsewhere are preserved
/// byte-exact. Returns the count of otrks removed.
fn remove_otrks_referencing_path(
    records: &mut Vec<TlvRecord>,
    path_tag: &[u8; 4],
    target_path: &str,
) -> usize {
    let encoded_target = HashSet::from([encode_utf16be(target_path)]);
    let original_len = records.len();
    records.retain(|record| {
        if &record.tag != TAG_OTRK || !otrk_has_path_in(&record.payload, path_tag, &encoded_target)
        {
            return true;
        }
        let Ok(nested) = TlvRecord::parse_all(&record.payload) else {
            // Unparseable otrk: preserve verbatim. Better to leave a
            // weird-but-existing entry alone than to drop something
            // we don't understand.
            return true;
        };
        let matches = nested.iter().any(|nested_record| {
            if nested_record.tag != *path_tag {
                return false;
            }
            decode_utf16be(&nested_record.payload).as_deref() == Some(target_path)
        });
        !matches
    });
    original_len - records.len()
}

fn rewrite_path_in_otrks(
    records: &mut [TlvRecord],
    path_tag: &[u8; 4],
    old_path: &str,
    new_path: &str,
) -> usize {
    let mut renames = HashMap::with_capacity(1);
    renames.insert(old_path.to_string(), new_path.to_string());
    rewrite_paths_in_otrks(records, path_tag, &renames)
}

/// Multi-rename variant: rewrite every otrk whose path field matches
/// any key in `renames`, replacing it with the mapped value. One pass
/// over the records; only otrks holding a rename source are parsed.
///
/// Every matching path field is rewritten, while `held_paths_in_otrks`
/// reads only the first decodable one. They differ only for an otrk with
/// several path fields, which Serato does not write; rewriting all of them
/// keeps such a record from pointing at the old path anywhere.
fn rewrite_paths_in_otrks(
    records: &mut [TlvRecord],
    path_tag: &[u8; 4],
    renames: &HashMap<String, String>,
) -> usize {
    if renames.is_empty() {
        return 0;
    }
    let encoded_sources: HashSet<Vec<u8>> = renames
        .keys()
        .map(|old_path| encode_utf16be(old_path))
        .collect();
    let mut count: usize = 0;
    for record in records.iter_mut() {
        if &record.tag != TAG_OTRK || !otrk_has_path_in(&record.payload, path_tag, &encoded_sources)
        {
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
            if let Some(new_path) = renames.get(&current) {
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
        // Pre-size to the known total. Skips the ~25 doubling
        // reallocations a fresh Vec::new() incurs on its way to
        // 25 MB+ output (the size of a real database V2 file).
        let estimated_size: usize = self
            .records
            .iter()
            .map(|record| 8 + record.payload.len())
            .sum();
        let mut bytes = Vec::with_capacity(estimated_size);
        TlvRecord::write_all(&self.records, &mut bytes)?;
        Ok(bytes)
    }

    pub fn write_to_path(&self, path: impl AsRef<Path>) -> Result<(), SeratoError> {
        let bytes = self.to_bytes()?;
        replace_file(path.as_ref(), |file| file.write_all(&bytes))?;
        Ok(())
    }

    pub fn track_paths(&self) -> Vec<String> {
        track_paths_in_otrks(&self.records, TAG_PTRK)
    }

    pub fn rewrite_path(&mut self, old_path: &str, new_path: &str) -> usize {
        rewrite_path_in_otrks(&mut self.records, TAG_PTRK, old_path, new_path)
    }

    /// Which of `paths` this crate holds a track at.
    pub fn held_paths<'path>(
        &self,
        paths: impl IntoIterator<Item = &'path str>,
    ) -> HashSet<String> {
        held_paths_in_otrks(&self.records, TAG_PTRK, paths)
    }

    /// Multi-rename variant: rewrite every matching `ptrk` in one pass.
    /// Caller layer pairs this with one read + one write of the
    /// crate file regardless of how many renames are batched.
    pub fn rewrite_paths(&mut self, renames: &HashMap<String, String>) -> usize {
        rewrite_paths_in_otrks(&mut self.records, TAG_PTRK, renames)
    }

    /// Drop every otrk in this crate whose `ptrk` points at
    /// `target_path`. Used by the duplicate-resolver after the file
    /// has been trashed so the crate no longer holds a broken
    /// reference. Other otrks in the crate (and non-otrk records)
    /// are preserved byte-exact.
    pub fn remove_track(&mut self, target_path: &str) -> usize {
        remove_otrks_referencing_path(&mut self.records, TAG_PTRK, target_path)
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
        // Pre-size to the known total. Skips the ~25 doubling
        // reallocations a fresh Vec::new() incurs on its way to
        // 25 MB+ output (the size of a real database V2 file).
        let estimated_size: usize = self
            .records
            .iter()
            .map(|record| 8 + record.payload.len())
            .sum();
        let mut bytes = Vec::with_capacity(estimated_size);
        TlvRecord::write_all(&self.records, &mut bytes)?;
        Ok(bytes)
    }

    pub fn write_to_path(&self, path: impl AsRef<Path>) -> Result<(), SeratoError> {
        let bytes = self.to_bytes()?;
        replace_file(path.as_ref(), |file| file.write_all(&bytes))?;
        Ok(())
    }

    pub fn track_paths(&self) -> Vec<String> {
        track_paths_in_otrks(&self.records, TAG_PFIL)
    }

    /// Full metadata records for every track entry. Where
    /// `track_paths()` returns only the `pfil` path, this also
    /// extracts the well-known `t*` text fields (artist, title,
    /// album, genre, BPM, key, comment, length, label) from each
    /// `otrk` container.
    ///
    /// Records without a `pfil` are skipped — an `otrk` entry that
    /// can't be located on disk has nothing useful to expose.
    pub fn track_records(&self) -> Vec<SeratoTrackRecord> {
        self.records
            .iter()
            .filter(|record| &record.tag == TAG_OTRK)
            .filter_map(|record| extract_track_record(&record.payload))
            .collect()
    }

    pub fn strict_track_records(&self) -> Result<Vec<SeratoTrackRecord>, SeratoError> {
        let Some(version) = self.records.first() else {
            return Err(SeratoError::InvalidFile("missing database version".into()));
        };
        if version.tag != *b"vrsn"
            || decode_utf16be(&version.payload).as_deref()
                != Some("2.0/Serato Scratch LIVE Database")
        {
            return Err(SeratoError::InvalidFile(
                "unsupported database version".into(),
            ));
        }
        let mut tracks = Vec::new();
        for record in &self.records[1..] {
            if record.tag == *b"vrsn" {
                return Err(SeratoError::InvalidFile(
                    "duplicate database version".into(),
                ));
            }
            if record.tag != *TAG_OTRK {
                continue;
            }
            let nested = TlvRecord::parse_all(&record.payload)?;
            let mut paths = nested.iter().filter(|field| field.tag == *TAG_PFIL);
            let path_field = paths
                .next()
                .ok_or_else(|| SeratoError::InvalidFile("otrk missing pfil".into()))?;
            if paths.next().is_some() {
                return Err(SeratoError::InvalidFile(
                    "otrk has multiple pfil fields".into(),
                ));
            }
            let path = decode_utf16be(&path_field.payload)
                .ok_or_else(|| SeratoError::InvalidUtf16 { tag: "pfil".into() })?;
            if path.is_empty() || path.contains('\0') {
                return Err(SeratoError::InvalidFile(
                    "otrk has an empty or NUL-containing path".into(),
                ));
            }
            for field in &nested {
                if matches!(
                    &field.tag,
                    b"tart"
                        | b"tsng"
                        | b"talb"
                        | b"tgen"
                        | b"tbpm"
                        | b"tkey"
                        | b"tcom"
                        | b"tlen"
                        | b"tlbl"
                ) && decode_utf16be(&field.payload).is_none()
                {
                    return Err(SeratoError::InvalidUtf16 {
                        tag: field.tag_str(),
                    });
                }
            }
            tracks.push(decode_track_fields(&nested, path));
        }
        Ok(tracks)
    }

    pub fn rewrite_path(&mut self, old_path: &str, new_path: &str) -> usize {
        rewrite_path_in_otrks(&mut self.records, TAG_PFIL, old_path, new_path)
    }

    /// Multi-rename variant: rewrite every matching `pfil` in one pass.
    /// Used by bulk Organize / Migrate — one read + one write of the
    /// (typically multi-MB) `database V2` file regardless of how many
    /// renames are in the batch.
    pub fn rewrite_paths(&mut self, renames: &HashMap<String, String>) -> usize {
        rewrite_paths_in_otrks(&mut self.records, TAG_PFIL, renames)
    }

    /// Drop every otrk whose `pfil` points at `target_path`. Used
    /// by the duplicate-resolver after the file has been trashed.
    /// Like `update_track_metadata` / `add_track`, must only be
    /// called while Serato is NOT running — Serato caches the
    /// library in memory and overwrites the disk version on save.
    /// The Swift caller gates via `SeratoWatchdog`.
    pub fn remove_track(&mut self, target_path: &str) -> usize {
        remove_otrks_referencing_path(&mut self.records, TAG_PFIL, target_path)
    }

    /// Which of `paths` this database holds a track at.
    pub fn held_paths<'path>(
        &self,
        paths: impl IntoIterator<Item = &'path str>,
    ) -> HashSet<String> {
        held_paths_in_otrks(&self.records, TAG_PFIL, paths)
    }

    /// Number of `otrk` track entries in the database. Useful for
    /// progress reporting on full library scans.
    pub fn track_count(&self) -> usize {
        self.records
            .iter()
            .filter(|record| &record.tag == TAG_OTRK)
            .count()
    }

    /// Append an `otrk` for each `(track_path, metadata)` addition whose
    /// path Serato does not already hold, in order. Used by crate-agent's
    /// import flow to register files with Serato without going through
    /// Serato's own UI. The existing paths are collected once, so a batch
    /// costs one pass over the library rather than one per addition.
    ///
    /// Returns one flag per addition: `true` if it was appended, `false`
    /// if Serato (or an earlier addition in this batch) already has the
    /// path — Serato dedupes itself, and mirroring that keeps the file
    /// from growing on repeated imports. As with the per-path matchers,
    /// an otrk that does not fully parse does not count as holding its path.
    ///
    /// Like `update_track_metadata`, must only be called while
    /// Serato is NOT running. The Swift caller gates via
    /// SeratoWatchdog.
    pub fn add_tracks(&mut self, additions: &[(String, SeratoMetadataUpdate)]) -> Vec<bool> {
        let mut present: HashSet<Vec<u8>> =
            HashSet::with_capacity(self.records.len() + additions.len());
        let mut otrk_paths: Vec<&[u8]> = Vec::new();
        for record in self.records.iter().filter(|record| &record.tag == TAG_OTRK) {
            otrk_paths.clear();
            let well_formed = walk_nested_fields(&record.payload, |tag, payload| {
                if tag == TAG_PFIL {
                    otrk_paths.push(payload);
                }
            });
            if well_formed {
                present.extend(otrk_paths.iter().map(|payload| payload.to_vec()));
            }
        }

        additions
            .iter()
            .map(|(track_path, metadata)| {
                let encoded_path = encode_utf16be(track_path);
                if !present.insert(encoded_path.clone()) {
                    return false;
                }
                let mut nested = vec![TlvRecord {
                    tag: *TAG_PFIL,
                    payload: encoded_path,
                }];
                // A fresh otrk starts empty, so every supplied field is new.
                let _ = apply_metadata_update_to_nested(&mut nested, metadata);
                let mut payload =
                    Vec::with_capacity(nested.iter().map(|field| 8 + field.payload.len()).sum());
                TlvRecord::write_all(&nested, &mut payload)
                    .expect("writing to Vec<u8> cannot fail");
                self.records.push(TlvRecord {
                    tag: *TAG_OTRK,
                    payload,
                });
                true
            })
            .collect()
    }

    /// Update Serato's metadata for the track whose `pfil` equals
    /// `track_path`. For each `Some(...)` field in `update`, the
    /// corresponding `t*` record is set (creating it if absent);
    /// `None` fields leave the existing record unchanged. Returns 1
    /// if a matching `otrk` was found and updated, 0 otherwise.
    ///
    /// Per-field semantics:
    /// - `Some(value)` writes that value (replaces or inserts the tag)
    /// - `None` leaves whatever is currently in the otrk alone
    /// - An empty `Some("")` writes an empty UTF-16BE payload — Serato
    ///   displays that as a blank field. To truly delete a tag, a
    ///   separate operation would be needed (not implemented).
    ///
    /// The `pfil` field itself is never touched; renames go through
    /// `rewrite_path` instead. Updating a path-renaming-shaped change
    /// here would produce inconsistent state.
    pub fn update_track_metadata(
        &mut self,
        track_path: &str,
        update: &SeratoMetadataUpdate,
    ) -> usize {
        for record in self.records.iter_mut() {
            if &record.tag != TAG_OTRK {
                continue;
            }
            let Ok(mut nested) = TlvRecord::parse_all(&record.payload) else {
                continue;
            };
            let path_matches = nested.iter().any(|field| {
                &field.tag == TAG_PFIL
                    && decode_utf16be(&field.payload).as_deref() == Some(track_path)
            });
            if !path_matches {
                continue;
            }

            let changed = apply_metadata_update_to_nested(&mut nested, update);
            if !changed {
                // Path matched but every supplied field already held
                // its target value. Skip the rebuild — and return 0
                // so the FFI caller skips the file write too. This
                // matters for the SP-2 MusicBrainz pass, which calls
                // update_database_record per track including ones
                // whose Serato metadata already matches.
                return 0;
            }

            let mut rebuilt = Vec::with_capacity(record.payload.len());
            TlvRecord::write_all(&nested, &mut rebuilt).expect("writing to Vec<u8> cannot fail");
            record.payload = rebuilt;
            return 1;
        }
        0
    }

    /// Bulk variant of `update_track_metadata`: apply a whole map of
    /// `pfil path -> update` in a SINGLE pass over the records, so the
    /// (typically multi-MB) `database V2` file is read and written once
    /// regardless of how many tracks are updated. This is the write-side
    /// twin of `rewrite_paths` for renames — a 200-row Auto-Tag apply
    /// would otherwise trigger 200 full-library read+rewrite cycles.
    ///
    /// Per-track semantics are identical to `update_track_metadata`
    /// (`Some` sets, `None` leaves alone, no-op when values already
    /// match). Returns the number of otrks actually changed; the FFI
    /// caller skips the file write when that is zero.
    pub fn batch_update_track_metadata(
        &mut self,
        updates: &HashMap<String, SeratoMetadataUpdate>,
    ) -> usize {
        if updates.is_empty() {
            return 0;
        }
        let mut changed_tracks = 0;
        for record in self.records.iter_mut() {
            if &record.tag != TAG_OTRK {
                continue;
            }
            let Ok(mut nested) = TlvRecord::parse_all(&record.payload) else {
                continue;
            };
            let Some(track_path) = first_decodable_path(&nested, TAG_PFIL) else {
                continue;
            };
            let Some(update) = updates.get(&track_path) else {
                continue;
            };
            if !apply_metadata_update_to_nested(&mut nested, update) {
                continue;
            }
            let mut rebuilt = Vec::with_capacity(record.payload.len());
            TlvRecord::write_all(&nested, &mut rebuilt).expect("writing to Vec<u8> cannot fail");
            record.payload = rebuilt;
            changed_tracks += 1;
        }
        changed_tracks
    }
}

/// Field-by-field update for the metadata fields crate-agent can
/// write back to Serato. `None` means "leave alone"; `Some(value)`
/// means "set to this value (creating the tag if it doesn't exist)".
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SeratoMetadataUpdate {
    pub artist: Option<String>,
    pub title: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub bpm: Option<String>,
    pub key: Option<String>,
    pub comment: Option<String>,
    pub length: Option<String>,
    pub label: Option<String>,
}

/// Returns true if any field was actually changed. False means the
/// update was a no-op (all-None, or every `Some(value)` equalled
/// the existing tag) and the caller can skip serialisation.
fn apply_metadata_update_to_nested(
    nested: &mut Vec<TlvRecord>,
    update: &SeratoMetadataUpdate,
) -> bool {
    let mut changed = false;
    if let Some(value) = &update.artist {
        changed |= set_or_insert_text_field(nested, b"tart", value);
    }
    if let Some(value) = &update.title {
        changed |= set_or_insert_text_field(nested, b"tsng", value);
    }
    if let Some(value) = &update.album {
        changed |= set_or_insert_text_field(nested, b"talb", value);
    }
    if let Some(value) = &update.genre {
        changed |= set_or_insert_text_field(nested, b"tgen", value);
    }
    if let Some(value) = &update.bpm {
        changed |= set_or_insert_text_field(nested, b"tbpm", value);
    }
    if let Some(value) = &update.key {
        changed |= set_or_insert_text_field(nested, b"tkey", value);
    }
    if let Some(value) = &update.comment {
        changed |= set_or_insert_text_field(nested, b"tcom", value);
    }
    if let Some(value) = &update.length {
        changed |= set_or_insert_text_field(nested, b"tlen", value);
    }
    if let Some(value) = &update.label {
        changed |= set_or_insert_text_field(nested, b"tlbl", value);
    }
    changed
}

/// Returns true if the otrk's nested records were actually modified.
/// A `Some(value)` that equals the existing tag value is treated as
/// a no-op so callers can skip the rebuild + file write.
fn set_or_insert_text_field(nested: &mut Vec<TlvRecord>, tag: &[u8; 4], value: &str) -> bool {
    let payload = encode_utf16be(value);
    if let Some(existing) = nested.iter_mut().find(|record| &record.tag == tag) {
        if existing.payload == payload {
            return false;
        }
        existing.payload = payload;
    } else {
        nested.push(TlvRecord { tag: *tag, payload });
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_otrk(path_tag: &[u8; 4], path: &str) -> TlvRecord {
        let path_record = TlvRecord {
            tag: *path_tag,
            payload: encode_utf16be(path),
        };
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&[path_record], &mut otrk_payload).unwrap();
        TlvRecord {
            tag: *TAG_OTRK,
            payload: otrk_payload,
        }
    }

    /// Build a synthetic library byte stream (works for either `.crate`
    /// or `database V2` depending on `path_tag`) containing the
    /// supplied version string and track paths.
    fn synthetic_library(version: &str, path_tag: &[u8; 4], paths: &[&str]) -> Vec<u8> {
        let mut records = vec![TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be(version),
        }];
        for path in paths {
            records.push(synthetic_otrk(path_tag, path));
        }
        let mut bytes = Vec::new();
        TlvRecord::write_all(&records, &mut bytes).unwrap();
        bytes
    }

    #[test]
    fn strict_membership_accepts_version_only_empty_library() {
        let bytes = synthetic_library("2.0/Serato Scratch LIVE Database", TAG_PFIL, &[]);
        assert!(DatabaseV2::from_bytes(&bytes)
            .unwrap()
            .strict_track_records()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn strict_membership_rejects_invalid_versions_and_empty_bytes() {
        for bytes in [
            Vec::new(),
            synthetic_library("", TAG_PFIL, &[]),
            synthetic_library("nonsense", TAG_PFIL, &[]),
        ] {
            assert!(DatabaseV2::from_bytes(&bytes)
                .unwrap()
                .strict_track_records()
                .is_err());
        }
    }

    #[test]
    fn strict_membership_rejects_malformed_tracks() {
        for payload in [
            Vec::new(),
            vec![0],
            b"pfil\0\0\0\0".to_vec(),
            vec![112, 102, 105, 108, 0, 0, 0, 2, 216, 0],
        ] {
            let mut bytes = synthetic_library("2.0/Serato Scratch LIVE Database", TAG_PFIL, &[]);
            TlvRecord::write_all(
                &[TlvRecord {
                    tag: *TAG_OTRK,
                    payload,
                }],
                &mut bytes,
            )
            .unwrap();
            assert!(DatabaseV2::from_bytes(&bytes)
                .unwrap()
                .strict_track_records()
                .is_err());
        }
    }

    #[test]
    fn strict_membership_rejects_truncated_and_excessive_lengths() {
        for bytes in [
            b"otrk".to_vec(),
            vec![111, 116, 114, 107, 255, 255, 255, 255],
        ] {
            assert!(DatabaseV2::from_bytes(&bytes).is_err());
        }
    }

    #[test]
    fn strict_membership_preserves_unknown_fields() {
        let mut bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Music/track.mp3"],
        );
        TlvRecord::write_all(
            &[TlvRecord {
                tag: *b"zzzz",
                payload: vec![255],
            }],
            &mut bytes,
        )
        .unwrap();
        let database = DatabaseV2::from_bytes(&bytes).unwrap();
        assert_eq!(
            database.strict_track_records().unwrap()[0].path,
            "Music/track.mp3"
        );
        assert_eq!(database.to_bytes().unwrap(), bytes);
    }

    #[test]
    fn strict_membership_validates_fields_without_changing_permissive_reader() {
        for invalid_field in [
            TlvRecord {
                tag: *b"tsng",
                payload: vec![216, 0],
            },
            TlvRecord {
                tag: *TAG_PFIL,
                payload: encode_utf16be("another.mp3"),
            },
        ] {
            let bytes = synthetic_library(
                "2.0/Serato Scratch LIVE Database",
                TAG_PFIL,
                &["Music/track.mp3"],
            );
            let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
            TlvRecord::write_all(&[invalid_field], &mut database.records[1].payload).unwrap();
            let database = DatabaseV2::from_bytes(&database.to_bytes().unwrap()).unwrap();
            assert!(database.strict_track_records().is_err());
            assert_eq!(database.track_records().len(), 1);
        }
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Music/track.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        TlvRecord::write_all(
            &[TlvRecord {
                tag: *b"zzzz",
                payload: vec![255],
            }],
            &mut database.records[1].payload,
        )
        .unwrap();
        let bytes = database.to_bytes().unwrap();
        let database = DatabaseV2::from_bytes(&bytes).unwrap();
        assert_eq!(database.strict_track_records().unwrap().len(), 1);
        assert_eq!(database.to_bytes().unwrap(), bytes);
    }

    // ===== CrateFile tests =====

    #[test]
    fn parses_synthetic_crate_and_returns_track_paths() {
        let bytes = synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &[
                "Music/A/Artist - Track A.mp3",
                "Music/B/Artist - Track B.mp3",
            ],
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
    fn crate_rewrite_paths_applies_every_rename_in_one_pass() {
        let mut parsed = CrateFile::from_bytes(&synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &[
                "Music/A/one.mp3",
                "Music/A/two.mp3",
                "Music/A/three.mp3",
                "Music/A/keep.mp3",
            ],
        ))
        .unwrap();

        let mut renames = HashMap::new();
        renames.insert("Music/A/one.mp3".to_string(), "Music/B/one.mp3".to_string());
        renames.insert("Music/A/two.mp3".to_string(), "Music/B/two.mp3".to_string());
        renames.insert(
            "Music/A/three.mp3".to_string(),
            "Music/B/three.mp3".to_string(),
        );

        let count = parsed.rewrite_paths(&renames);

        assert_eq!(count, 3, "three matching otrks should be rewritten");
        assert_eq!(
            parsed.track_paths(),
            vec![
                "Music/B/one.mp3".to_string(),
                "Music/B/two.mp3".to_string(),
                "Music/B/three.mp3".to_string(),
                "Music/A/keep.mp3".to_string(),
            ]
        );
    }

    #[test]
    fn crate_rewrite_paths_with_empty_map_is_noop() {
        let bytes = synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &["Music/A/track.mp3"],
        );
        let mut parsed = CrateFile::from_bytes(&bytes).unwrap();
        let count = parsed.rewrite_paths(&HashMap::new());
        assert_eq!(count, 0);
        assert_eq!(parsed.to_bytes().unwrap(), bytes);
    }

    #[test]
    fn crate_rewrite_path_preserves_other_nested_fields_in_otrk() {
        // Synthesize an otrk containing both a ptrk and an unknown tag.
        let ptrk = TlvRecord {
            tag: *TAG_PTRK,
            payload: encode_utf16be("Music/A/old.mp3"),
        };
        let unknown = TlvRecord {
            tag: *b"zzzz",
            payload: vec![0xDE, 0xAD, 0xBE, 0xEF],
        };
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&[ptrk, unknown.clone()], &mut otrk_payload).unwrap();

        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("1.0/Serato ScratchLive Crate"),
        };
        let otrk = TlvRecord {
            tag: *TAG_OTRK,
            payload: otrk_payload,
        };
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
        assert_eq!(
            decode_utf16be(&nested[0].payload).unwrap(),
            "Music/A/new.mp3"
        );
        assert_eq!(
            nested[1], unknown,
            "unknown nested record must be byte-identical"
        );
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
    fn a_write_that_fails_before_the_rename_leaves_the_original_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("database V2");
        fs::write(&path, b"original library").unwrap();
        let unrelated = directory.path().join(".crate-agent-notes.txt");
        fs::write(&unrelated, b"not ours").unwrap();
        fs::write(
            directory.path().join(".crate-agent-Ab12Cd.tmp"),
            b"crashed rewrite",
        )
        .unwrap();

        let result = replace_file(&path, |file| {
            file.write_all(b"partial")?;
            Err(std::io::Error::other("disk full"))
        });

        assert!(result.is_err());
        assert_eq!(fs::read(&path).unwrap(), b"original library");
        let mut remaining: Vec<_> = fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        remaining.sort();
        assert_eq!(
            remaining,
            [".crate-agent-notes.txt", "database V2"],
            "a temporary file was left behind, or an unrelated file was removed"
        );
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
            vec![
                "Music/T/Track A.mp3".to_string(),
                "Music/T/Track B.mp3".to_string()
            ]
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
    fn database_rewrite_paths_applies_every_rename_in_one_pass() {
        let mut parsed = DatabaseV2::from_bytes(&synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &[
                "Music/A/a.mp3",
                "Music/A/b.mp3",
                "Music/A/c.mp3",
                "Music/A/keep.mp3",
            ],
        ))
        .unwrap();

        let mut renames = HashMap::new();
        renames.insert("Music/A/a.mp3".to_string(), "Music/B/a.mp3".to_string());
        renames.insert("Music/A/b.mp3".to_string(), "Music/B/b.mp3".to_string());
        renames.insert("Music/A/c.mp3".to_string(), "Music/B/c.mp3".to_string());

        let count = parsed.rewrite_paths(&renames);

        assert_eq!(count, 3);
        assert_eq!(
            parsed.track_paths(),
            vec![
                "Music/B/a.mp3".to_string(),
                "Music/B/b.mp3".to_string(),
                "Music/B/c.mp3".to_string(),
                "Music/A/keep.mp3".to_string(),
            ]
        );
    }

    #[test]
    fn database_rewrite_path_preserves_other_metadata_in_otrk() {
        // Synthesize a realistic-ish otrk containing pfil + tart (artist)
        // + tsng (title) + tbpm (BPM) + a future unknown tag. Rewriting
        // pfil must not touch the metadata fields.
        let pfil = TlvRecord {
            tag: *TAG_PFIL,
            payload: encode_utf16be("Music/A/old.mp3"),
        };
        let tart = TlvRecord {
            tag: *b"tart",
            payload: encode_utf16be("Some Artist"),
        };
        let tsng = TlvRecord {
            tag: *b"tsng",
            payload: encode_utf16be("Some Track"),
        };
        let tbpm = TlvRecord {
            tag: *b"tbpm",
            payload: encode_utf16be("128.000"),
        };
        let unknown = TlvRecord {
            tag: *b"q9q9",
            payload: vec![1, 2, 3, 4, 5],
        };

        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(
            &[
                pfil,
                tart.clone(),
                tsng.clone(),
                tbpm.clone(),
                unknown.clone(),
            ],
            &mut otrk_payload,
        )
        .unwrap();

        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        };
        let otrk = TlvRecord {
            tag: *TAG_OTRK,
            payload: otrk_payload,
        };
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
        assert_eq!(
            decode_utf16be(&nested[0].payload).unwrap(),
            "Music/A/new.mp3"
        );
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

    #[test]
    fn database_track_records_extracts_well_known_metadata_tags() {
        // Synthesize a single otrk containing pfil + the full set of
        // metadata tags we extract, plus an unknown tag (`zzzz`) to
        // verify it's silently ignored.
        fn nested(tag: &[u8; 4], value: &str) -> TlvRecord {
            TlvRecord {
                tag: *tag,
                payload: encode_utf16be(value),
            }
        }
        let otrk_fields = [
            nested(TAG_PFIL, "Users/x/Music/A/Track.mp3"),
            nested(b"tart", "Some Artist"),
            nested(b"tsng", "Some Title"),
            nested(b"talb", "Some Album"),
            nested(b"tgen", "House"),
            nested(b"tbpm", "128.000"),
            nested(b"tkey", "Am"),
            nested(b"tcom", "a comment"),
            nested(b"tlen", "03:24"),
            nested(b"tlbl", "Some Label"),
            TlvRecord {
                tag: *b"zzzz",
                payload: vec![1, 2, 3, 4],
            },
        ];
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&otrk_fields, &mut otrk_payload).unwrap();
        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        };
        let otrk = TlvRecord {
            tag: *TAG_OTRK,
            payload: otrk_payload,
        };
        let mut bytes = Vec::new();
        TlvRecord::write_all(&[vrsn, otrk], &mut bytes).unwrap();

        let database = DatabaseV2::from_bytes(&bytes).unwrap();
        let records = database.track_records();
        assert_eq!(records.len(), 1);
        let track = &records[0];
        assert_eq!(track.path, "Users/x/Music/A/Track.mp3");
        assert_eq!(track.artist.as_deref(), Some("Some Artist"));
        assert_eq!(track.title.as_deref(), Some("Some Title"));
        assert_eq!(track.album.as_deref(), Some("Some Album"));
        assert_eq!(track.genre.as_deref(), Some("House"));
        assert_eq!(track.bpm.as_deref(), Some("128.000"));
        assert_eq!(track.key.as_deref(), Some("Am"));
        assert_eq!(track.comment.as_deref(), Some("a comment"));
        assert_eq!(track.length.as_deref(), Some("03:24"));
        assert_eq!(track.label.as_deref(), Some("Some Label"));
    }

    #[test]
    fn database_track_records_returns_none_for_otrk_without_pfil() {
        // An otrk that has tart but no pfil — useless to crate-agent
        // (no file to match against), should be skipped.
        let tart_only = TlvRecord {
            tag: *b"tart",
            payload: encode_utf16be("Ghost Artist"),
        };
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&[tart_only], &mut otrk_payload).unwrap();
        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        };
        let mut bytes = Vec::new();
        TlvRecord::write_all(
            &[
                vrsn,
                TlvRecord {
                    tag: *TAG_OTRK,
                    payload: otrk_payload,
                },
            ],
            &mut bytes,
        )
        .unwrap();

        let database = DatabaseV2::from_bytes(&bytes).unwrap();
        assert_eq!(database.track_records().len(), 0);
    }

    #[test]
    fn database_track_records_leaves_optional_fields_none_when_tags_absent() {
        // Only path present — every other field should be None.
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/path-only.mp3"],
        );
        let database = DatabaseV2::from_bytes(&bytes).unwrap();
        let records = database.track_records();
        assert_eq!(records.len(), 1);
        let track = &records[0];
        assert_eq!(track.path, "Users/x/Music/A/path-only.mp3");
        assert!(track.artist.is_none());
        assert!(track.title.is_none());
        assert!(track.album.is_none());
        assert!(track.bpm.is_none());
    }

    // ===== Metadata write-back tests =====

    #[test]
    fn update_track_metadata_replaces_existing_tag_value() {
        fn nested(tag: &[u8; 4], value: &str) -> TlvRecord {
            TlvRecord {
                tag: *tag,
                payload: encode_utf16be(value),
            }
        }
        let otrk_fields = [
            nested(TAG_PFIL, "Users/x/Music/A/Track.mp3"),
            nested(b"tart", "Original Artist"),
            nested(b"tbpm", "120.000"),
        ];
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&otrk_fields, &mut otrk_payload).unwrap();
        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        };
        let otrk = TlvRecord {
            tag: *TAG_OTRK,
            payload: otrk_payload,
        };
        let mut bytes = Vec::new();
        TlvRecord::write_all(&[vrsn, otrk], &mut bytes).unwrap();
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();

        let update = SeratoMetadataUpdate {
            artist: Some("New Artist".to_string()),
            bpm: Some("128.000".to_string()),
            ..Default::default()
        };
        let updated = database.update_track_metadata("Users/x/Music/A/Track.mp3", &update);
        assert_eq!(updated, 1);

        let records = database.track_records();
        assert_eq!(records[0].artist.as_deref(), Some("New Artist"));
        assert_eq!(records[0].bpm.as_deref(), Some("128.000"));
    }

    #[test]
    fn update_track_metadata_inserts_new_tag_when_absent() {
        // Otrk has only pfil — no tart yet. Updating artist must
        // INSERT a tart record, not silently skip.
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/Track.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();

        let update = SeratoMetadataUpdate {
            artist: Some("Brand New Artist".to_string()),
            ..Default::default()
        };
        let updated = database.update_track_metadata("Users/x/Music/A/Track.mp3", &update);
        assert_eq!(updated, 1);

        let records = database.track_records();
        assert_eq!(records[0].artist.as_deref(), Some("Brand New Artist"));
    }

    #[test]
    fn update_track_metadata_leaves_unspecified_fields_alone() {
        fn nested(tag: &[u8; 4], value: &str) -> TlvRecord {
            TlvRecord {
                tag: *tag,
                payload: encode_utf16be(value),
            }
        }
        let otrk_fields = [
            nested(TAG_PFIL, "Users/x/Music/A/Track.mp3"),
            nested(b"tart", "Original Artist"),
            nested(b"tsng", "Original Title"),
            nested(b"tbpm", "120.000"),
        ];
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&otrk_fields, &mut otrk_payload).unwrap();
        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        };
        let mut bytes = Vec::new();
        TlvRecord::write_all(
            &[
                vrsn,
                TlvRecord {
                    tag: *TAG_OTRK,
                    payload: otrk_payload,
                },
            ],
            &mut bytes,
        )
        .unwrap();
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();

        // Only update artist; title and bpm should survive untouched.
        let update = SeratoMetadataUpdate {
            artist: Some("New Artist".to_string()),
            ..Default::default()
        };
        database.update_track_metadata("Users/x/Music/A/Track.mp3", &update);

        let records = database.track_records();
        assert_eq!(records[0].artist.as_deref(), Some("New Artist"));
        assert_eq!(records[0].title.as_deref(), Some("Original Title"));
        assert_eq!(records[0].bpm.as_deref(), Some("120.000"));
    }

    #[test]
    fn update_track_metadata_returns_zero_for_unknown_path() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/exists.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let update = SeratoMetadataUpdate {
            artist: Some("Anything".to_string()),
            ..Default::default()
        };
        let updated = database.update_track_metadata("Users/x/Music/Z/missing.mp3", &update);
        assert_eq!(updated, 0);
    }

    // ===== add_track tests =====

    #[test]
    fn add_track_appends_new_otrk_with_path_and_metadata() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/existing.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        assert_eq!(database.track_count(), 1);

        let metadata = SeratoMetadataUpdate {
            artist: Some("New Artist".to_string()),
            title: Some("New Title".to_string()),
            bpm: Some("128.000".to_string()),
            ..Default::default()
        };
        let added = database.add_tracks(&[("Users/x/Music/A/new.mp3".to_string(), metadata)]);
        assert_eq!(added, [true], "should report added");
        assert_eq!(database.track_count(), 2);

        // Re-parse to verify both tracks are addressable as records.
        let serialized = database.to_bytes().unwrap();
        let reparsed = DatabaseV2::from_bytes(&serialized).unwrap();
        let records = reparsed.track_records();
        assert_eq!(records.len(), 2);

        let new_record = records
            .iter()
            .find(|record| record.path == "Users/x/Music/A/new.mp3");
        let new_record = new_record.expect("new track present in re-parsed database");
        assert_eq!(new_record.artist.as_deref(), Some("New Artist"));
        assert_eq!(new_record.title.as_deref(), Some("New Title"));
        assert_eq!(new_record.bpm.as_deref(), Some("128.000"));
    }

    #[test]
    fn add_track_with_no_metadata_writes_only_pfil() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/existing.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let added = database.add_tracks(&[(
            "Users/x/Music/A/bare.mp3".to_string(),
            SeratoMetadataUpdate::default(),
        )]);
        assert_eq!(added, [true]);

        let records = database.track_records();
        let bare = records
            .iter()
            .find(|record| record.path == "Users/x/Music/A/bare.mp3")
            .unwrap();
        assert!(bare.artist.is_none());
        assert!(bare.title.is_none());
        assert!(bare.bpm.is_none());
    }

    #[test]
    fn remove_track_drops_matching_otrk_from_database() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &[
                "Users/x/Music/A/keep1.mp3",
                "Users/x/Music/A/remove.mp3",
                "Users/x/Music/A/keep2.mp3",
            ],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let removed = database.remove_track("Users/x/Music/A/remove.mp3");
        assert_eq!(removed, 1);
        assert_eq!(database.track_count(), 2);
        let after = DatabaseV2::from_bytes(&database.to_bytes().unwrap()).unwrap();
        let paths = after.track_paths();
        assert!(paths.contains(&"Users/x/Music/A/keep1.mp3".to_string()));
        assert!(paths.contains(&"Users/x/Music/A/keep2.mp3".to_string()));
        assert!(!paths.contains(&"Users/x/Music/A/remove.mp3".to_string()));
    }

    #[test]
    fn remove_track_returns_zero_for_unknown_path_in_database() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/Track.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let removed = database.remove_track("Users/x/Music/A/nonexistent.mp3");
        assert_eq!(removed, 0);
        assert_eq!(database.track_count(), 1, "no otrks dropped on a miss");
    }

    #[test]
    fn remove_track_drops_matching_otrk_from_crate() {
        // Build a synthetic crate file (TAG_PTRK as the path tag).
        let bytes = synthetic_library(
            "1.0/Serato ScratchLive Crate",
            TAG_PTRK,
            &["Users/x/Music/A/keep.mp3", "Users/x/Music/A/remove.mp3"],
        );
        let mut crate_file = CrateFile::from_bytes(&bytes).unwrap();
        let removed = crate_file.remove_track("Users/x/Music/A/remove.mp3");
        assert_eq!(removed, 1);
        let after = CrateFile::from_bytes(&crate_file.to_bytes().unwrap()).unwrap();
        let paths = after.track_paths();
        assert_eq!(paths, vec!["Users/x/Music/A/keep.mp3"]);
    }

    // ===== path pre-filter adversarial fixtures =====

    // The tail `瑳湧\0\u{4}ab` encodes as a complete `tsng` field holding
    // "ab", so an otrk storing `Music/Café/` followed by that field holds
    // the target's UTF-16BE bytes contiguously across the field boundary.
    const PREFILTER_TARGET: &str = "Music/Caf\u{e9}/\u{7473}\u{6e67}\u{0}\u{4}ab";
    const PREFILTER_PREFIX: &str = "Music/Caf\u{e9}/";
    const PREFILTER_RENAMED: &str = "Music/Renamed.mp3";

    fn raw_field(tag: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut bytes = tag.to_vec();
        bytes.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_be_bytes());
        bytes.extend_from_slice(payload);
        bytes
    }

    fn raw_path(path_tag: &[u8; 4], path: &str) -> Vec<u8> {
        raw_field(path_tag, &encode_utf16be(path))
    }

    fn otrk_from_fields(fields: &[Vec<u8>]) -> TlvRecord {
        TlvRecord {
            tag: *TAG_OTRK,
            payload: fields.concat(),
        }
    }

    /// The otrks whose path field is exactly `path`: one with the path
    /// first, one holding it in a second path field.
    fn otrks_holding(path_tag: &[u8; 4], path: &str) -> [TlvRecord; 2] {
        [
            otrk_from_fields(&[
                raw_path(path_tag, path),
                raw_field(b"tart", &encode_utf16be("Kept")),
            ]),
            otrk_from_fields(&[
                raw_path(path_tag, "Music/Other.mp3"),
                raw_path(path_tag, path),
            ]),
        ]
    }

    /// An otrk whose path field matches but whose trailing field is
    /// truncated, so it does not parse.
    fn truncated_otrk_holding_target(path_tag: &[u8; 4]) -> TlvRecord {
        otrk_from_fields(&[raw_path(path_tag, PREFILTER_TARGET), b"tsng\0\0".to_vec()])
    }

    /// Records that contain the target's UTF-16BE bytes, or bytes that
    /// nearly match, without any path field equal to the target.
    fn non_matching_records(path_tag: &[u8; 4]) -> Vec<TlvRecord> {
        let target = encode_utf16be(PREFILTER_TARGET);
        let other = raw_path(path_tag, "Music/Other.mp3");
        let fake_header = raw_field(path_tag, &target);
        vec![
            TlvRecord {
                tag: *b"zzzz",
                payload: fake_header.clone(),
            },
            otrk_from_fields(&[raw_path(path_tag, &format!("{PREFILTER_TARGET}.bak"))]),
            otrk_from_fields(&[raw_path(path_tag, &format!("X{PREFILTER_TARGET}"))]),
            otrk_from_fields(&[raw_path(
                path_tag,
                &PREFILTER_TARGET[..PREFILTER_TARGET.len() - 1],
            )]),
            otrk_from_fields(&[raw_path(
                path_tag,
                &PREFILTER_TARGET.replace('\u{e9}', "e\u{301}"),
            )]),
            otrk_from_fields(&[other.clone(), raw_field(b"tcom", &target)]),
            otrk_from_fields(&[other.clone(), raw_field(b"tcom", &fake_header)]),
            otrk_from_fields(&[
                other,
                raw_field(b"bbgl", &[&[0], target.as_slice()].concat()),
            ]),
            otrk_from_fields(&[
                raw_path(path_tag, PREFILTER_PREFIX),
                raw_field(b"tsng", &encode_utf16be("ab")),
            ]),
            truncated_otrk_holding_target(path_tag),
        ]
    }

    /// The version record, every non-matching record, and the matching
    /// otrks for `path` interleaved among them.
    fn prefilter_library(path_tag: &[u8; 4], matching_path: &str) -> Vec<TlvRecord> {
        let [first, second] = otrks_holding(path_tag, matching_path);
        let mut records = vec![TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        }];
        let others = non_matching_records(path_tag);
        let (front, back) = others.split_at(others.len() / 2);
        records.extend_from_slice(front);
        records.push(first);
        records.extend_from_slice(back);
        records.push(second);
        records
    }

    #[test]
    fn path_removal_matches_only_exact_path_fields() {
        for path_tag in [TAG_PFIL, TAG_PTRK] {
            let records = prefilter_library(path_tag, PREFILTER_TARGET);
            let target = encode_utf16be(PREFILTER_TARGET);
            let straddling = &non_matching_records(path_tag)[8].payload;
            assert!(
                straddling
                    .windows(target.len())
                    .any(|window| window == target),
                "the split fixture must hold the target bytes across its field boundary"
            );
            let mut expected = vec![records[0].clone()];
            expected.extend(non_matching_records(path_tag));
            let (removed, remaining) = if path_tag == TAG_PFIL {
                let mut database = DatabaseV2 { records };
                (database.remove_track(PREFILTER_TARGET), database.records)
            } else {
                let mut crate_file = CrateFile { records };
                (
                    crate_file.remove_track(PREFILTER_TARGET),
                    crate_file.records,
                )
            };
            assert_eq!(removed, 2);
            assert_eq!(remaining, expected);
        }
    }

    #[test]
    fn path_rewrite_matches_only_exact_path_fields() {
        for path_tag in [TAG_PFIL, TAG_PTRK] {
            let renames =
                HashMap::from([(PREFILTER_TARGET.to_string(), PREFILTER_RENAMED.to_string())]);
            let records = prefilter_library(path_tag, PREFILTER_TARGET);
            let (rewritten, result) = if path_tag == TAG_PFIL {
                let mut database = DatabaseV2 { records };
                (database.rewrite_paths(&renames), database.records)
            } else {
                let mut crate_file = CrateFile { records };
                (crate_file.rewrite_paths(&renames), crate_file.records)
            };
            assert_eq!(rewritten, 2);
            assert_eq!(result, prefilter_library(path_tag, PREFILTER_RENAMED));
        }
    }

    #[test]
    fn batch_add_skips_paths_already_held_and_repeated_in_the_batch() {
        let mut database = DatabaseV2 {
            records: prefilter_library(TAG_PFIL, PREFILTER_TARGET),
        };
        let original = database.records.clone();
        let metadata = SeratoMetadataUpdate {
            title: Some("Imported".to_string()),
            ..Default::default()
        };
        let additions = [
            PREFILTER_TARGET,
            "Music/New.mp3",
            &PREFILTER_TARGET.replace('\u{e9}', "e\u{301}"),
            "Music/New.mp3",
        ]
        .map(|path| (path.to_string(), metadata.clone()));
        assert_eq!(database.add_tracks(&additions), [false, true, false, false]);
        assert_eq!(database.records[..original.len()], original[..]);
        assert_eq!(database.records.len(), original.len() + 1);
        let added = extract_track_record(&database.records[original.len()].payload).unwrap();
        assert_eq!(added.path, "Music/New.mp3");
        assert_eq!(added.title.as_deref(), Some("Imported"));

        let mut malformed_only = DatabaseV2 {
            records: vec![truncated_otrk_holding_target(TAG_PFIL)],
        };
        assert_eq!(
            malformed_only.add_tracks(&[(PREFILTER_TARGET.to_string(), metadata)]),
            [true],
            "an otrk that does not parse does not hold its path"
        );
    }

    #[test]
    fn remove_track_preserves_non_otrk_records_in_database() {
        // The synthetic_library helper produces vrsn + otrk records.
        // Removing all otrks must leave vrsn intact.
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/only.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let removed = database.remove_track("Users/x/Music/A/only.mp3");
        assert_eq!(removed, 1);
        let after = DatabaseV2::from_bytes(&database.to_bytes().unwrap()).unwrap();
        // Database has no otrks left but the vrsn header survived.
        assert_eq!(after.track_count(), 0);
        // Reading via track_records returns empty (no otrks) but the
        // file still serializes without errors — proves vrsn is intact.
        assert!(after.to_bytes().is_ok());
    }

    #[test]
    fn update_track_metadata_with_empty_update_is_byte_exact_noop() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/Track.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let update = SeratoMetadataUpdate::default();
        let updated = database.update_track_metadata("Users/x/Music/A/Track.mp3", &update);

        // An all-None update is a true no-op: the function returns 0
        // (so the FFI caller skips the file write) and the bytes
        // round-trip byte-exact since we never rebuilt the otrk.
        assert_eq!(updated, 0);
        assert_eq!(database.to_bytes().unwrap(), bytes);
    }

    #[test]
    fn update_track_metadata_returns_zero_when_supplied_values_already_match() {
        // Set up an otrk whose tart is already "Some Artist", then
        // call update with artist=Some("Some Artist"). No fields
        // changed → return 0, bytes byte-exact.
        let pfil = TlvRecord {
            tag: *TAG_PFIL,
            payload: encode_utf16be("Music/A/x.mp3"),
        };
        let tart = TlvRecord {
            tag: *b"tart",
            payload: encode_utf16be("Some Artist"),
        };
        let mut otrk_payload = Vec::new();
        TlvRecord::write_all(&[pfil, tart], &mut otrk_payload).unwrap();
        let vrsn = TlvRecord {
            tag: *b"vrsn",
            payload: encode_utf16be("2.0/Serato Scratch LIVE Database"),
        };
        let otrk = TlvRecord {
            tag: *TAG_OTRK,
            payload: otrk_payload,
        };
        let mut db_bytes = Vec::new();
        TlvRecord::write_all(&[vrsn, otrk], &mut db_bytes).unwrap();

        let mut database = DatabaseV2::from_bytes(&db_bytes).unwrap();
        let update = SeratoMetadataUpdate {
            artist: Some("Some Artist".to_string()),
            ..SeratoMetadataUpdate::default()
        };
        let updated = database.update_track_metadata("Music/A/x.mp3", &update);

        assert_eq!(updated, 0);
        assert_eq!(database.to_bytes().unwrap(), db_bytes);
    }

    #[test]
    fn batch_update_track_metadata_updates_every_matching_track_in_one_pass() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &[
                "Users/x/Music/A/one.mp3",
                "Users/x/Music/A/two.mp3",
                "Users/x/Music/A/three.mp3",
            ],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();

        let mut updates = HashMap::new();
        updates.insert(
            "Users/x/Music/A/one.mp3".to_string(),
            SeratoMetadataUpdate {
                artist: Some("Artist One".to_string()),
                ..Default::default()
            },
        );
        updates.insert(
            "Users/x/Music/A/three.mp3".to_string(),
            SeratoMetadataUpdate {
                title: Some("Title Three".to_string()),
                ..Default::default()
            },
        );

        let changed = database.batch_update_track_metadata(&updates);
        // Two of the three otrks matched an update entry; the middle
        // one was left alone.
        assert_eq!(changed, 2);

        let after = DatabaseV2::from_bytes(&database.to_bytes().unwrap()).unwrap();
        let records = after.track_records();
        assert_eq!(records[0].artist.as_deref(), Some("Artist One"));
        assert!(records[1].artist.is_none());
        assert!(records[1].title.is_none());
        assert_eq!(records[2].title.as_deref(), Some("Title Three"));
    }

    #[test]
    fn batch_update_track_metadata_empty_map_is_noop() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/one.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let changed = database.batch_update_track_metadata(&HashMap::new());
        assert_eq!(changed, 0);
        assert_eq!(database.to_bytes().unwrap(), bytes);
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
        let database =
            DatabaseV2::read_from_path(&path).expect("real database V2 must parse cleanly");
        let otrk_count = database.track_count();
        let path_count = database.track_paths().len();
        let file_size = std::fs::metadata(&path).unwrap().len();
        eprintln!(
            "real database V2: {} bytes, {} otrk records, {} pfil paths decoded",
            file_size, otrk_count, path_count
        );
        assert!(otrk_count > 0, "expected a non-empty database");
        assert_eq!(
            otrk_count, path_count,
            "every otrk should expose exactly one pfil"
        );

        // Track-record extraction: count records and tally how many
        // populated each well-known metadata field. Useful as a
        // sanity check on real-world data — emits the tallies via
        // eprintln so devs can see field coverage without printing
        // any actual track names.
        let records = database.track_records();
        let mut artist_count = 0;
        let mut title_count = 0;
        let mut bpm_count = 0;
        let mut key_count = 0;
        for record in &records {
            if record.artist.is_some() {
                artist_count += 1;
            }
            if record.title.is_some() {
                title_count += 1;
            }
            if record.bpm.is_some() {
                bpm_count += 1;
            }
            if record.key.is_some() {
                key_count += 1;
            }
        }
        eprintln!(
            "metadata coverage: {} records, {} with artist, {} with title, {} with bpm, {} with key",
            records.len(), artist_count, title_count, bpm_count, key_count
        );
        assert_eq!(
            records.len(),
            path_count,
            "every otrk with a pfil should yield a record"
        );

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
