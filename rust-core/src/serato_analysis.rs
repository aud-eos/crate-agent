// Serato's per-track analysis, read from the audio file's own tags.
//
// Layouts follow https://github.com/Holzhaus/serato-tags:
//   MPEG, AIFF, WAV   ID3v2 GEOB frames `Serato Markers2` and `Serato BeatGrid`
//   MP4               freeform atoms `com.serato.dj:markersv2` and `:beatgrid`
//   FLAC              Vorbis comments `SERATO_MARKERS_V2` and `SERATO_BEATGRID`
// The MP4 and FLAC values are base64 of an envelope that carries the same
// bytes as the GEOB frame's data. Ogg uses other keys and a different
// layout, and Opus and Speex have none documented, so they are unsupported.

use std::path::Path;

use base64::alphabet::STANDARD;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig};
use base64::engine::DecodePaddingMode;
use base64::Engine;
use lofty::config::ParseOptions;
use lofty::file::{AudioFile, FileType};
use lofty::flac::FlacFile;
use lofty::id3::v2::{Frame, GeneralEncapsulatedObject, Id3v2Tag};
use lofty::iff::aiff::AiffFile;
use lofty::iff::wav::WavFile;
use lofty::mp4::{AtomData, AtomIdent, Ilst, Mp4File};
use lofty::mpeg::MpegFile;
use lofty::ogg::VorbisComments;
use lofty::probe::Probe;
use thiserror::Error;

const MARKERS2_DESCRIPTOR: &str = "Serato Markers2";
const BEATGRID_DESCRIPTOR: &str = "Serato BeatGrid";
const MP4_MEAN: &str = "com.serato.dj";
const ENVELOPE_PREFIX: &[u8] = b"application/octet-stream\0\0";
const MARKERS2_VERSION: [u8; 2] = [0x01, 0x01];
const BEATGRID_VERSION: [u8; 2] = [0x01, 0x00];
const BEATGRID_MARKER_LENGTH: usize = 8;
const CUE_MINIMUM_LENGTH: usize = 13;

/// Serato wraps its base64 every 72 characters, sometimes omits padding, and
/// can leave one dangling character, which serato-tags completes with `A`.
const LENIENT_BASE64: GeneralPurpose = GeneralPurpose::new(
    &STANDARD,
    GeneralPurposeConfig::new()
        .with_decode_allow_trailing_bits(true)
        .with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeratoAnalysis {
    pub cue_count: u32,
    pub beatgrid_marker_count: u32,
}

#[derive(Debug, Error)]
pub enum AnalysisError {
    #[error("unsupported format: {0}")]
    UnsupportedFormat(String),
    #[error("unreadable file: {0}")]
    Unreadable(String),
    #[error("malformed {field}: {reason}")]
    Malformed { field: &'static str, reason: String },
}

fn malformed(field: &'static str, reason: impl Into<String>) -> AnalysisError {
    AnalysisError::Malformed {
        field,
        reason: reason.into(),
    }
}

/// The two Serato payloads, each in the form an ID3 GEOB frame carries it.
#[derive(Default)]
struct SeratoPayloads {
    markers2: Option<Vec<u8>>,
    beatgrid: Option<Vec<u8>>,
}

pub fn read_serato_analysis(path: &Path) -> Result<SeratoAnalysis, AnalysisError> {
    let payloads = read_payloads(path)?;
    let cue_count = match payloads.markers2 {
        Some(data) => count_markers2_cues(&decode_markers2_geob(&data)?)?,
        None => 0,
    };
    let beatgrid_marker_count = match payloads.beatgrid {
        Some(data) => count_beatgrid_markers(&data)?,
        None => 0,
    };
    Ok(SeratoAnalysis {
        cue_count,
        beatgrid_marker_count,
    })
}

fn read_payloads(path: &Path) -> Result<SeratoPayloads, AnalysisError> {
    let unreadable = |error: &dyn std::fmt::Display| AnalysisError::Unreadable(error.to_string());
    let options = ParseOptions::new().read_properties(false);
    let probe = Probe::open(path)
        .map_err(|error| unreadable(&error))?
        .options(options)
        .guess_file_type()
        .map_err(|error| unreadable(&error))?;
    let file_type = probe.file_type();
    let mut reader = probe.into_inner();
    match file_type {
        Some(FileType::Mpeg) => {
            MpegFile::read_from(&mut reader, options).map(|file| id3_payloads(file.id3v2()))
        }
        Some(FileType::Aiff) => {
            AiffFile::read_from(&mut reader, options).map(|file| id3_payloads(file.id3v2()))
        }
        Some(FileType::Wav) => {
            WavFile::read_from(&mut reader, options).map(|file| id3_payloads(file.id3v2()))
        }
        Some(FileType::Mp4) => {
            Mp4File::read_from(&mut reader, options).map(|file| mp4_payloads(file.ilst()))
        }
        Some(FileType::Flac) => FlacFile::read_from(&mut reader, options)
            .map(|file| flac_payloads(file.vorbis_comments())),
        Some(other) => {
            return Err(AnalysisError::UnsupportedFormat(format!("{other:?}")));
        }
        None => {
            return Err(AnalysisError::UnsupportedFormat(
                "unrecognised audio container".into(),
            ));
        }
    }
    .map_err(|error| unreadable(&error))?
}

fn id3_payloads(tag: Option<&Id3v2Tag>) -> Result<SeratoPayloads, AnalysisError> {
    let mut payloads = SeratoPayloads::default();
    for frame in tag.into_iter().flatten() {
        let Frame::Binary(binary) = frame else {
            continue;
        };
        if binary.id().as_str() != "GEOB" {
            continue;
        }
        let object = GeneralEncapsulatedObject::parse(&binary.data, binary.flags())
            .map_err(|error| malformed("GEOB frame", error.to_string()))?;
        match object.descriptor.as_deref() {
            Some(MARKERS2_DESCRIPTOR) => payloads.markers2 = Some(object.data),
            Some(BEATGRID_DESCRIPTOR) => payloads.beatgrid = Some(object.data),
            _ => {}
        }
    }
    Ok(payloads)
}

fn mp4_payloads(ilst: Option<&Ilst>) -> Result<SeratoPayloads, AnalysisError> {
    let Some(ilst) = ilst else {
        return Ok(SeratoPayloads::default());
    };
    let atom_text = |name: &'static str| -> Result<Option<Vec<u8>>, AnalysisError> {
        let ident = AtomIdent::Freeform {
            mean: MP4_MEAN.into(),
            name: name.into(),
        };
        let Some(atom) = ilst.get(&ident) else {
            return Ok(None);
        };
        match atom.data().next() {
            Some(AtomData::UTF8(text)) => Ok(Some(text.clone().into_bytes())),
            Some(AtomData::Unknown { data, .. }) => Ok(Some(data.clone())),
            _ => Err(malformed(
                "MP4 Serato atom",
                format!("unexpected {name} data"),
            )),
        }
    };
    Ok(SeratoPayloads {
        markers2: atom_text("markersv2")?
            .map(|text| unwrap_envelope(&text, MARKERS2_DESCRIPTOR))
            .transpose()?,
        beatgrid: atom_text("beatgrid")?
            .map(|text| unwrap_envelope(&text, BEATGRID_DESCRIPTOR))
            .transpose()?,
    })
}

fn flac_payloads(comments: Option<&VorbisComments>) -> Result<SeratoPayloads, AnalysisError> {
    let Some(comments) = comments else {
        return Ok(SeratoPayloads::default());
    };
    let field = |key: &str, descriptor: &str| {
        comments
            .get(key)
            .map(|text| unwrap_envelope(text.as_bytes(), descriptor))
            .transpose()
    };
    Ok(SeratoPayloads {
        markers2: field("SERATO_MARKERS_V2", MARKERS2_DESCRIPTOR)?,
        beatgrid: field("SERATO_BEATGRID", BEATGRID_DESCRIPTOR)?,
    })
}

fn decode_lenient_base64(text: &[u8], field: &'static str) -> Result<Vec<u8>, AnalysisError> {
    let mut cleaned: Vec<u8> = text
        .iter()
        .copied()
        .filter(|byte| !byte.is_ascii_whitespace() && *byte != b'=')
        .collect();
    if cleaned.len() % 4 == 1 {
        cleaned.push(b'A');
    }
    LENIENT_BASE64
        .decode(&cleaned)
        .map_err(|error| malformed(field, format!("invalid base64: {error}")))
}

/// The GEOB-form payload inside an MP4 or Vorbis value: base64 of the MIME
/// type, an empty file name and the descriptor, each NUL-terminated.
fn unwrap_envelope(text: &[u8], descriptor: &str) -> Result<Vec<u8>, AnalysisError> {
    let decoded = decode_lenient_base64(text, "Serato envelope")?;
    let mut header = ENVELOPE_PREFIX.to_vec();
    header.extend_from_slice(descriptor.as_bytes());
    header.push(0);
    decoded
        .strip_prefix(header.as_slice())
        .map(<[u8]>::to_vec)
        .ok_or_else(|| malformed("Serato envelope", format!("missing {descriptor} header")))
}

fn decode_markers2_geob(data: &[u8]) -> Result<Vec<u8>, AnalysisError> {
    let text = data
        .strip_prefix(&MARKERS2_VERSION)
        .ok_or_else(|| malformed(MARKERS2_DESCRIPTOR, "unsupported version"))?;
    let text = text.split(|byte| *byte == 0).next().unwrap_or_default();
    decode_lenient_base64(text, MARKERS2_DESCRIPTOR)
}

fn count_markers2_cues(body: &[u8]) -> Result<u32, AnalysisError> {
    let mut remaining = body
        .strip_prefix(&MARKERS2_VERSION)
        .ok_or_else(|| malformed(MARKERS2_DESCRIPTOR, "unsupported version"))?;
    let mut cue_count = 0;
    while let Some((&first, _)) = remaining.split_first() {
        if first == 0 {
            break;
        }
        let type_end = remaining
            .iter()
            .position(|byte| *byte == 0)
            .ok_or_else(|| malformed(MARKERS2_DESCRIPTOR, "unterminated entry type"))?;
        let entry_type = &remaining[..type_end];
        let after_type = &remaining[type_end + 1..];
        let (length_bytes, after_length) = after_type
            .split_first_chunk::<4>()
            .ok_or_else(|| malformed(MARKERS2_DESCRIPTOR, "truncated entry length"))?;
        let length = usize::try_from(u32::from_be_bytes(*length_bytes))
            .map_err(|_| malformed(MARKERS2_DESCRIPTOR, "entry length overflow"))?;
        if after_length.len() < length {
            return Err(malformed(MARKERS2_DESCRIPTOR, "truncated entry data"));
        }
        let (entry_data, rest) = after_length.split_at(length);
        if entry_type == b"CUE" {
            if entry_data.len() < CUE_MINIMUM_LENGTH || entry_data.last() != Some(&0) {
                return Err(malformed(MARKERS2_DESCRIPTOR, "short cue entry"));
            }
            cue_count += 1;
        }
        remaining = rest;
    }
    Ok(cue_count)
}

/// Header, `marker_count` markers of 8 bytes each, then one footer byte.
fn count_beatgrid_markers(data: &[u8]) -> Result<u32, AnalysisError> {
    let after_version = data
        .strip_prefix(&BEATGRID_VERSION)
        .ok_or_else(|| malformed(BEATGRID_DESCRIPTOR, "unsupported version"))?;
    let (count_bytes, markers_and_footer) = after_version
        .split_first_chunk::<4>()
        .ok_or_else(|| malformed(BEATGRID_DESCRIPTOR, "truncated marker count"))?;
    let marker_count = u32::from_be_bytes(*count_bytes);
    let expected_length = usize::try_from(marker_count)
        .ok()
        .and_then(|count| count.checked_mul(BEATGRID_MARKER_LENGTH))
        .and_then(|length| length.checked_add(1));
    if expected_length != Some(markers_and_footer.len()) {
        return Err(malformed(
            BEATGRID_DESCRIPTOR,
            "marker count does not match its length",
        ));
    }
    Ok(marker_count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
    use base64::Engine;
    use lofty::config::{ParseOptions, WriteOptions};
    use lofty::file::AudioFile;
    use lofty::id3::v2::{BinaryFrame, Frame, FrameId, GeneralEncapsulatedObject, Id3v2Tag};
    use lofty::iff::wav::WavFile;
    use lofty::TextEncoding;
    use std::borrow::Cow;
    use std::io::Write;

    fn entry(kind: &str, data: &[u8]) -> Vec<u8> {
        let mut bytes = kind.as_bytes().to_vec();
        bytes.push(0);
        bytes.extend_from_slice(&u32::try_from(data.len()).unwrap().to_be_bytes());
        bytes.extend_from_slice(data);
        bytes
    }

    fn cue(index: u8) -> Vec<u8> {
        let mut data = vec![0, index];
        data.extend_from_slice(&(u32::from(index) * 1_000).to_be_bytes());
        data.extend_from_slice(&[0, 0xcc, 0x00, 0x00, 0, 0]);
        data.extend_from_slice(b"Drop\0");
        entry("CUE", &data)
    }

    fn loop_entry(index: u8) -> Vec<u8> {
        let mut data = vec![0, index];
        data.extend_from_slice(&1_000u32.to_be_bytes());
        data.extend_from_slice(&5_000u32.to_be_bytes());
        data.extend_from_slice(&[0xff, 0xff, 0xff, 0xff, 0, 0x27, 0xaa, 0xe1, 0, 0, 0]);
        entry("LOOP", &data)
    }

    fn markers2_body(entries: &[Vec<u8>]) -> Vec<u8> {
        let mut body = vec![0x01, 0x01];
        for entry_bytes in entries {
            body.extend_from_slice(entry_bytes);
        }
        body.push(0);
        body
    }

    fn wrap_every_72(text: &str) -> Vec<u8> {
        text.as_bytes().chunks(72).collect::<Vec<_>>().join(&b'\n')
    }

    fn geob_payload(body: &[u8]) -> Vec<u8> {
        let mut payload = vec![0x01, 0x01];
        payload.extend(wrap_every_72(&STANDARD_NO_PAD.encode(body)));
        payload
    }

    fn envelope(descriptor: &str, inner: &[u8]) -> Vec<u8> {
        let mut bytes = b"application/octet-stream\0\0".to_vec();
        bytes.extend_from_slice(descriptor.as_bytes());
        bytes.push(0);
        bytes.extend_from_slice(inner);
        wrap_every_72(&STANDARD_NO_PAD.encode(bytes))
    }

    fn beatgrid(marker_count: u32) -> Vec<u8> {
        let mut data = vec![0x01, 0x00];
        data.extend_from_slice(&marker_count.to_be_bytes());
        for _ in 0..marker_count {
            data.extend_from_slice(&0.05f32.to_be_bytes());
            data.extend_from_slice(&128.0f32.to_be_bytes());
        }
        data.push(0);
        data
    }

    fn standard_body() -> Vec<u8> {
        markers2_body(&[
            cue(0),
            cue(1),
            entry("COLOR", &[0, 0xff, 0xff, 0xff]),
            entry("BPMLOCK", &[1]),
            loop_entry(0),
        ])
    }

    #[test]
    fn markers2_counts_cue_entries_and_ignores_color_bpmlock_and_loops() {
        let body = standard_body();
        assert_eq!(
            count_markers2_cues(&decode_markers2_geob(&geob_payload(&body)).unwrap()).unwrap(),
            2
        );
    }

    #[test]
    fn markers2_base64_tolerates_newlines_missing_padding_and_a_dangling_character() {
        let body = standard_body();
        assert_ne!(body.len() % 3, 0, "the body must need padding");
        let mut padded = vec![0x01, 0x01];
        padded.extend(STANDARD.encode(&body).into_bytes());

        let mut zero_filled = body.clone();
        zero_filled.resize(body.len().next_multiple_of(3), 0);
        let mut dangling = vec![0x01, 0x01];
        dangling.extend(wrap_every_72(&STANDARD_NO_PAD.encode(&zero_filled)));
        dangling.push(b'A');

        for payload in [geob_payload(&body), padded, dangling] {
            assert_eq!(
                count_markers2_cues(&decode_markers2_geob(&payload).unwrap()).unwrap(),
                2
            );
        }
    }

    #[test]
    fn malformed_markers2_is_an_error_not_zero() {
        assert!(count_markers2_cues(&[0x01, 0x01, b'C', b'U']).is_err());
    }

    fn write_empty_flac(path: &Path) {
        let mut stream_info = Vec::new();
        stream_info.extend_from_slice(&4_096u16.to_be_bytes());
        stream_info.extend_from_slice(&4_096u16.to_be_bytes());
        stream_info.extend_from_slice(&[0; 6]);
        let sample_rate_channels_bits: u64 = (44_100 << 44) | (15 << 36);
        stream_info.extend_from_slice(&sample_rate_channels_bits.to_be_bytes());
        stream_info.extend_from_slice(&[0; 16]);
        let mut bytes = b"fLaC".to_vec();
        bytes.push(0x80);
        bytes.extend_from_slice(&u32::try_from(stream_info.len()).unwrap().to_be_bytes()[1..]);
        bytes.extend_from_slice(&stream_info);
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn flac_vorbis_comments_read_cues_and_grid() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tagged.flac");
        write_empty_flac(&path);
        let mut flac = FlacFile::read_from(
            &mut std::fs::File::open(&path).unwrap(),
            ParseOptions::new(),
        )
        .unwrap();
        let mut comments = VorbisComments::default();
        comments.insert(
            "SERATO_MARKERS_V2".into(),
            String::from_utf8(envelope(
                MARKERS2_DESCRIPTOR,
                &geob_payload(&markers2_body(&[cue(0), cue(1), cue(2)])),
            ))
            .unwrap(),
        );
        comments.insert(
            "SERATO_BEATGRID".into(),
            String::from_utf8(envelope(BEATGRID_DESCRIPTOR, &beatgrid(2))).unwrap(),
        );
        flac.set_vorbis_comments(comments);
        flac.save_to_path(&path, WriteOptions::default()).unwrap();

        assert_eq!(
            read_serato_analysis(&path).unwrap(),
            SeratoAnalysis {
                cue_count: 3,
                beatgrid_marker_count: 2
            }
        );
    }

    fn write_silent_wav(path: &Path) {
        let data_size: u32 = 4_410 * 2;
        let mut file = std::fs::File::create(path).unwrap();
        file.write_all(b"RIFF").unwrap();
        file.write_all(&(36 + data_size).to_le_bytes()).unwrap();
        file.write_all(b"WAVEfmt ").unwrap();
        file.write_all(&16u32.to_le_bytes()).unwrap();
        file.write_all(&1u16.to_le_bytes()).unwrap();
        file.write_all(&1u16.to_le_bytes()).unwrap();
        file.write_all(&44_100u32.to_le_bytes()).unwrap();
        file.write_all(&88_200u32.to_le_bytes()).unwrap();
        file.write_all(&2u16.to_le_bytes()).unwrap();
        file.write_all(&16u16.to_le_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&data_size.to_le_bytes()).unwrap();
        file.write_all(&vec![0u8; data_size as usize]).unwrap();
    }

    fn geob_frame(descriptor: &str, data: Vec<u8>) -> Frame<'static> {
        let object = GeneralEncapsulatedObject::new(
            TextEncoding::Latin1,
            Some("application/octet-stream".into()),
            None,
            Some(descriptor.into()),
            data,
        );
        Frame::Binary(BinaryFrame::new(
            FrameId::Valid(Cow::Borrowed("GEOB")),
            object.as_bytes(WriteOptions::default()).unwrap(),
        ))
    }

    #[test]
    fn wav_with_id3_geob_reads_cues_and_grid_and_untagged_wav_reads_zero() {
        let directory = tempfile::tempdir().unwrap();
        let tagged = directory.path().join("tagged.wav");
        let untagged = directory.path().join("untagged.wav");
        write_silent_wav(&tagged);
        write_silent_wav(&untagged);

        let mut wav = WavFile::read_from(
            &mut std::fs::File::open(&tagged).unwrap(),
            ParseOptions::new(),
        )
        .unwrap();
        let mut tag = Id3v2Tag::new();
        tag.insert(geob_frame(
            "Serato Markers2",
            geob_payload(&markers2_body(&[cue(0), cue(1)])),
        ));
        tag.insert(geob_frame("Serato BeatGrid", beatgrid(1)));
        wav.set_id3v2(tag);
        wav.save_to_path(&tagged, WriteOptions::default()).unwrap();

        assert_eq!(
            read_serato_analysis(&tagged).unwrap(),
            SeratoAnalysis {
                cue_count: 2,
                beatgrid_marker_count: 1
            }
        );
        assert_eq!(
            read_serato_analysis(&untagged).unwrap(),
            SeratoAnalysis {
                cue_count: 0,
                beatgrid_marker_count: 0
            }
        );
    }
}
