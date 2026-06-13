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

use std::collections::HashMap;
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
            cursor
                .read_exact(&mut length_bytes)
                .map_err(|_| SeratoError::UnexpectedEof {
                    offset: offset_after_tag,
                    needed: 4,
                })?;
            let length = u32::from_be_bytes(length_bytes) as usize;

            let offset_after_length = cursor.position();
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
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    // Stream the u16 units through char::decode_utf16 directly into
    // a String — no intermediate Vec<u16>. `read_database_records`
    // calls this up to 10× per otrk; a 20k-track read previously
    // allocated 200k transient vectors.
    char::decode_utf16(
        bytes
            .chunks_exact(2)
            .map(|chunk| u16::from_be_bytes([chunk[0], chunk[1]])),
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

    for field in &nested {
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

    Some(track)
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

/// Replace every `otrk` whose `path_tag` payload decodes to `old_path`
/// with one whose `path_tag` payload encodes `new_path`. Preserves all
/// other fields nested inside the `otrk` container byte-exact. Returns
/// the number of `otrk` records whose path was rewritten.
/// Drop every top-level `otrk` whose path field (`pfil` for
/// database V2, `ptrk` for `.crate`) matches `target_path`.
/// Non-otrk records and otrks pointing elsewhere are preserved
/// byte-exact. Returns the count of otrks removed.
fn remove_otrks_referencing_path(
    records: &mut Vec<TlvRecord>,
    path_tag: &[u8; 4],
    target_path: &str,
) -> usize {
    let original_len = records.len();
    records.retain(|record| {
        if &record.tag != TAG_OTRK {
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
/// over the records, HashMap-O(1) lookup per matching nested record.
///
/// Cost vs. N separate `rewrite_path` calls: one file read + one file
/// write at the caller layer instead of N + N. The per-otrk nested
/// parse cost is unchanged — but it was already paid by every otrk
/// regardless of rename target, so batching doesn't make it worse.
fn rewrite_paths_in_otrks(
    records: &mut [TlvRecord],
    path_tag: &[u8; 4],
    renames: &HashMap<String, String>,
) -> usize {
    if renames.is_empty() {
        return 0;
    }
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
        std::fs::write(path.as_ref(), bytes)?;
        Ok(())
    }

    pub fn track_paths(&self) -> Vec<String> {
        track_paths_in_otrks(&self.records, TAG_PTRK)
    }

    pub fn rewrite_path(&mut self, old_path: &str, new_path: &str) -> usize {
        rewrite_path_in_otrks(&mut self.records, TAG_PTRK, old_path, new_path)
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
        std::fs::write(path.as_ref(), bytes)?;
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

    /// Number of `otrk` track entries in the database. Useful for
    /// progress reporting on full library scans.
    pub fn track_count(&self) -> usize {
        self.records
            .iter()
            .filter(|record| &record.tag == TAG_OTRK)
            .count()
    }

    /// Append a new `otrk` for `track_path` with the supplied
    /// metadata fields. Used by crate-agent's drag-drop import flow
    /// to register a file with Serato without going through Serato's
    /// own UI.
    ///
    /// Returns `true` if the track was added, `false` if Serato
    /// already has an otrk for this path (no-op — Serato dedupes
    /// itself, but we mirror that behavior to keep the file size
    /// from drifting on repeated imports).
    ///
    /// Like `update_track_metadata`, must only be called while
    /// Serato is NOT running. The Swift caller gates via
    /// SeratoWatchdog.
    pub fn add_track(&mut self, track_path: &str, metadata: &SeratoMetadataUpdate) -> bool {
        let already_present = self.records.iter().any(|record| {
            if &record.tag != TAG_OTRK {
                return false;
            }
            let Ok(nested) = TlvRecord::parse_all(&record.payload) else {
                return false;
            };
            nested.iter().any(|field| {
                &field.tag == TAG_PFIL
                    && decode_utf16be(&field.payload).as_deref() == Some(track_path)
            })
        });
        if already_present {
            return false;
        }

        let mut nested = vec![TlvRecord {
            tag: *TAG_PFIL,
            payload: encode_utf16be(track_path),
        }];
        // Return value ignored: a fresh otrk starts empty so every
        // supplied field is by definition new — for an add_track the
        // mutation always counts.
        let _ = apply_metadata_update_to_nested(&mut nested, metadata);

        let mut payload = Vec::with_capacity(nested.iter().map(|r| 8 + r.payload.len()).sum());
        TlvRecord::write_all(&nested, &mut payload).expect("writing to Vec<u8> cannot fail");
        self.records.push(TlvRecord {
            tag: *TAG_OTRK,
            payload,
        });
        true
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
        let added = database.add_track("Users/x/Music/A/new.mp3", &metadata);
        assert!(added, "should report added");
        assert_eq!(database.track_count(), 2);

        // Re-parse to verify both tracks are addressable as records.
        let serialized = database.to_bytes().unwrap();
        let reparsed = DatabaseV2::from_bytes(&serialized).unwrap();
        let records = reparsed.track_records();
        assert_eq!(records.len(), 2);

        let new_record = records.iter().find(|r| r.path == "Users/x/Music/A/new.mp3");
        let new_record = new_record.expect("new track present in re-parsed database");
        assert_eq!(new_record.artist.as_deref(), Some("New Artist"));
        assert_eq!(new_record.title.as_deref(), Some("New Title"));
        assert_eq!(new_record.bpm.as_deref(), Some("128.000"));
    }

    #[test]
    fn add_track_is_idempotent_for_existing_path() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/dup.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let metadata = SeratoMetadataUpdate {
            artist: Some("Ignored".to_string()),
            ..Default::default()
        };
        let added = database.add_track("Users/x/Music/A/dup.mp3", &metadata);
        assert!(!added, "duplicate add must be a no-op");
        assert_eq!(database.track_count(), 1);

        // The pre-existing otrk's metadata should be unchanged —
        // add_track only handles inserts, not updates. The
        // existing entry had no `tart`, so it should still have none.
        let records = database.track_records();
        assert_eq!(records.len(), 1);
        assert!(
            records[0].artist.is_none(),
            "existing entry's metadata is untouched"
        );
    }

    #[test]
    fn add_track_with_no_metadata_writes_only_pfil() {
        let bytes = synthetic_library(
            "2.0/Serato Scratch LIVE Database",
            TAG_PFIL,
            &["Users/x/Music/A/existing.mp3"],
        );
        let mut database = DatabaseV2::from_bytes(&bytes).unwrap();
        let added =
            database.add_track("Users/x/Music/A/bare.mp3", &SeratoMetadataUpdate::default());
        assert!(added);

        let records = database.track_records();
        let bare = records
            .iter()
            .find(|r| r.path == "Users/x/Music/A/bare.mp3")
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
