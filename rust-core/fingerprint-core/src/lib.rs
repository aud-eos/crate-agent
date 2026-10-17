// Audio fingerprinting via Chromaprint.
//
// Decodes audio with `symphonia` (broad codec support — MP3, FLAC, WAV,
// AIFF, ALAC, AAC, OGG Vorbis) and feeds the resulting PCM samples to
// `rusty_chromaprint` to produce a perceptual fingerprint stable across
// re-encodings and bitrate changes.
//
// We cap the audio fed to Chromaprint at the first 120 seconds. The
// perceptual hash converges well before that point — AcoustID's `fpcalc`
// and MusicBrainz Picard both use 120s as the default for the same
// reason. For a typical 4-minute DJ track this means we decode ~50% of
// the file instead of 100%, roughly tripling throughput on a full-
// library fingerprint pass without affecting duplicate-detection or
// SP-2 AcoustID lookup quality.
//
// The Swift FingerprintWorker drives this in a worker pool sized to
// CPU cores − 2; this module exposes a single-threaded function per
// file and lets the caller manage concurrency.

/// Maximum audio duration fed to Chromaprint per file. Beyond this
/// point the perceptual hash has converged and additional decode
/// work doesn't improve match quality — it just slows the pass.
pub const FINGERPRINT_MAX_DURATION_SECONDS: u64 = 120;

use std::fs::File;
use std::path::Path;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use rusty_chromaprint::{Configuration, FingerprintCompressor, Fingerprinter};
use sha2::{Digest, Sha256};
use symphonia::core::audio::GenericAudioBufferRef;
use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum FingerprintError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("audio decode error: {0}")]
    Decode(String),
    #[error("no default audio track in file")]
    NoAudioTracks,
    #[error("missing required codec parameter: {0}")]
    MissingCodecParameter(&'static str),
    #[error("fingerprinter rejected sample rate/channel configuration: {0}")]
    UnsupportedAudioConfig(String),
}

/// A failed read (EIO, a drive dropping mid-decode) may succeed later, so it
/// stays an I/O error; a stream that ends early is a property of the file.
impl From<SymphoniaError> for FingerprintError {
    fn from(err: SymphoniaError) -> Self {
        match err {
            SymphoniaError::IoError(io_err)
                if io_err.kind() != std::io::ErrorKind::UnexpectedEof =>
            {
                FingerprintError::Io(io_err)
            }
            other => FingerprintError::Decode(other.to_string()),
        }
    }
}

/// How much of a file's audio `fingerprint_file_with_extent` feeds to
/// Chromaprint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FingerprintExtent {
    /// The first `FINGERPRINT_MAX_DURATION_SECONDS`, matching AcoustID.
    AcoustIdWindow,
    /// Every decoded frame.
    FullLength,
}

/// Decode an audio file and return its Chromaprint fingerprint over the
/// first `FINGERPRINT_MAX_DURATION_SECONDS`.
///
/// The fingerprint is a sequence of 32-bit hashes covering the audio's
/// perceptual signature. Stable across re-encoding (WAV ↔ MP3 320, etc.)
/// within Chromaprint's perceptual tolerance.
pub fn fingerprint_file(path: impl AsRef<Path>) -> Result<Vec<u32>, FingerprintError> {
    fingerprint_file_with_extent(path, FingerprintExtent::AcoustIdWindow)
}

pub fn fingerprint_file_with_extent(
    path: impl AsRef<Path>,
    extent: FingerprintExtent,
) -> Result<Vec<u32>, FingerprintError> {
    let mut source = AudioSource::open(path.as_ref())?;
    let mut fingerprinter = ChromaprintSink::start(&source)?;
    let max_frames = match extent {
        FingerprintExtent::AcoustIdWindow => {
            Some(source.sample_rate as u64 * FINGERPRINT_MAX_DURATION_SECONDS)
        }
        FingerprintExtent::FullLength => None,
    };
    source.decode(max_frames, |event| {
        if let DecodeEvent::Buffer(buffer) = event {
            fingerprinter.consume(buffer);
        }
    })?;
    Ok(fingerprinter.finish())
}

/// Identity of a file's decoded audio, independent of its tags and
/// container bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedAudioDigest {
    /// SHA-256 over `PCM_DIGEST_DOMAIN`, the sample rate (u32 LE) and the
    /// channel count (u32 LE), then the decoded stream at the native rate,
    /// interleaved, little-endian and lossless: integer samples widened to
    /// i32 (symphonia's exact left-shift conversion) and float samples in
    /// their native f32 or f64. A one-byte sample-format tag precedes the
    /// first buffer and any change of format, so packet boundaries never
    /// affect the digest. A packet that fails to decode adds a skip marker
    /// and its timestamp in place of audio.
    pub pcm_sha256: [u8; 32],
    /// `<container>/<codec>` short names from symphonia, e.g.
    /// `wav/pcm_s16le` or `mp3/mp3`. Equal formats can be compared by PCM.
    pub format: String,
    pub sample_rate: u32,
    pub channel_count: u32,
    pub frame_count: u64,
    /// SHA-256 of the full-length Chromaprint fingerprint (u32 LE values),
    /// for comparing different formats where PCM can't match.
    pub full_fingerprint_sha256: [u8; 32],
}

pub const PCM_DIGEST_DOMAIN: &[u8] = b"crate-agent decoded pcm v2\0";

const SKIPPED_PACKET_MARKER: &[u8] = b"\0skipped packet\0";

#[derive(Clone, Copy, PartialEq, Eq)]
enum CanonicalSampleFormat {
    Integer32 = 1,
    Float32 = 2,
    Float64 = 3,
}

/// Hashes decoded buffers losslessly at their native precision.
struct PcmHasher {
    hasher: Sha256,
    format: Option<CanonicalSampleFormat>,
    integers: Vec<i32>,
    floats: Vec<f32>,
    doubles: Vec<f64>,
    bytes: Vec<u8>,
}

impl PcmHasher {
    fn new(source: &AudioSource) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(PCM_DIGEST_DOMAIN);
        hasher.update(source.sample_rate.to_le_bytes());
        hasher.update(source.channel_count.to_le_bytes());
        Self {
            hasher,
            format: None,
            integers: Vec::new(),
            floats: Vec::new(),
            doubles: Vec::new(),
            bytes: Vec::new(),
        }
    }

    fn consume(&mut self, buffer: &GenericAudioBufferRef<'_>) {
        let length = buffer.samples_interleaved();
        let format = match buffer {
            GenericAudioBufferRef::F32(_) => CanonicalSampleFormat::Float32,
            GenericAudioBufferRef::F64(_) => CanonicalSampleFormat::Float64,
            _ => CanonicalSampleFormat::Integer32,
        };
        if self.format != Some(format) {
            self.hasher.update([format as u8]);
            self.format = Some(format);
        }
        self.bytes.clear();
        match format {
            CanonicalSampleFormat::Integer32 => {
                resize_for(&mut self.integers, length);
                buffer.copy_to_slice_interleaved(&mut self.integers);
                self.bytes
                    .extend(self.integers.iter().flat_map(|sample| sample.to_le_bytes()));
            }
            CanonicalSampleFormat::Float32 => {
                resize_for(&mut self.floats, length);
                buffer.copy_to_slice_interleaved(&mut self.floats);
                self.bytes
                    .extend(self.floats.iter().flat_map(|sample| sample.to_le_bytes()));
            }
            CanonicalSampleFormat::Float64 => {
                resize_for(&mut self.doubles, length);
                buffer.copy_to_slice_interleaved(&mut self.doubles);
                self.bytes
                    .extend(self.doubles.iter().flat_map(|sample| sample.to_le_bytes()));
            }
        }
        self.hasher.update(&self.bytes);
    }

    fn skipped(&mut self, packet_timestamp: i64) {
        self.hasher.update(SKIPPED_PACKET_MARKER);
        self.hasher.update(packet_timestamp.to_le_bytes());
    }
}

/// Decode the whole file once, hashing its PCM and fingerprinting its full
/// length in the same pass.
pub fn decoded_audio_digest(
    path: impl AsRef<Path>,
) -> Result<DecodedAudioDigest, FingerprintError> {
    let mut source = AudioSource::open(path.as_ref())?;
    let mut fingerprinter = ChromaprintSink::start(&source)?;
    let mut pcm = PcmHasher::new(&source);
    let frame_count = source.decode(None, |event| match event {
        DecodeEvent::Buffer(buffer) => {
            pcm.consume(buffer);
            fingerprinter.consume(buffer);
        }
        DecodeEvent::Skipped { packet_timestamp } => pcm.skipped(packet_timestamp),
    })?;
    let mut fingerprint_hasher = Sha256::new();
    for value in fingerprinter.finish() {
        fingerprint_hasher.update(value.to_le_bytes());
    }
    Ok(DecodedAudioDigest {
        pcm_sha256: pcm.hasher.finalize().into(),
        format: source.format_name,
        sample_rate: source.sample_rate,
        channel_count: source.channel_count,
        frame_count,
        full_fingerprint_sha256: fingerprint_hasher.finalize().into(),
    })
}

/// Only grow, never shrink: `copy_to_slice_interleaved` overwrites every
/// element, so re-zeroing on each packet would be wasted work.
fn resize_for<Sample: Copy + Default>(buffer: &mut Vec<Sample>, length: usize) {
    if buffer.len() < length {
        buffer.resize(length, Sample::default());
    } else {
        buffer.truncate(length);
    }
}

enum DecodeEvent<'buffer, 'samples> {
    Buffer(&'buffer GenericAudioBufferRef<'samples>),
    Skipped { packet_timestamp: i64 },
}

struct AudioSource {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    sample_rate: u32,
    channel_count: u32,
    format_name: String,
}

impl AudioSource {
    fn open(path: &Path) -> Result<Self, FingerprintError> {
        let file = File::open(path)?;
        let media_source = MediaSourceStream::new(Box::new(file), Default::default());

        let mut hint = Hint::new();
        if let Some(ext) = path.extension().and_then(|ext| ext.to_str()) {
            hint.with_extension(ext);
        }

        let format = symphonia::default::get_probe()
            .probe(
                &hint,
                media_source,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(FingerprintError::from)?;

        let track = format
            .default_track(TrackType::Audio)
            .ok_or(FingerprintError::NoAudioTracks)?;
        let track_id = track.id;

        let codec_params = track
            .codec_params
            .as_ref()
            .ok_or(FingerprintError::MissingCodecParameter("codec_params"))?
            .audio()
            .ok_or(FingerprintError::MissingCodecParameter(
                "audio_codec_params",
            ))?;

        let sample_rate = codec_params
            .sample_rate
            .ok_or(FingerprintError::MissingCodecParameter("sample_rate"))?;
        let channel_count = codec_params
            .channels
            .as_ref()
            .ok_or(FingerprintError::MissingCodecParameter("channels"))?
            .count() as u32;

        let codecs = symphonia::default::get_codecs();
        let codec_name = codecs
            .get_audio_decoder(codec_params.codec)
            .map(|registered| registered.codec.info.short_name)
            .ok_or_else(|| {
                FingerprintError::Decode(format!("unsupported codec {}", codec_params.codec))
            })?;
        let format_name = format!("{}/{}", format.format_info().short_name, codec_name);

        let decoder = codecs
            .make_audio_decoder(codec_params, &AudioDecoderOptions::default())
            .map_err(FingerprintError::from)?;

        Ok(Self {
            format,
            decoder,
            track_id,
            sample_rate,
            channel_count,
            format_name,
        })
    }

    /// Feeds each decoded buffer of the default track to `sink`, stopping
    /// once `max_frames` have been delivered, and returns the frame count.
    /// A packet that fails to decode is reported as `Skipped` and otherwise
    /// skipped, as one bad frame should not abort reading an entire track.
    fn decode(
        &mut self,
        max_frames: Option<u64>,
        mut sink: impl FnMut(DecodeEvent<'_, '_>),
    ) -> Result<u64, FingerprintError> {
        let mut frames_decoded: u64 = 0;
        while let Some(packet) = self.format.next_packet().map_err(FingerprintError::from)? {
            if packet.track_id != self.track_id {
                continue;
            }
            match self.decoder.decode(&packet) {
                Ok(buffer) => {
                    sink(DecodeEvent::Buffer(&buffer));
                    frames_decoded += buffer.frames() as u64;
                    if max_frames.is_some_and(|limit| frames_decoded >= limit) {
                        break;
                    }
                }
                Err(SymphoniaError::DecodeError(_)) => sink(DecodeEvent::Skipped {
                    packet_timestamp: packet.pts.get(),
                }),
                Err(other) => return Err(other.into()),
            }
        }
        Ok(frames_decoded)
    }
}

struct ChromaprintSink {
    fingerprinter: Fingerprinter,
    samples: Vec<i16>,
}

impl ChromaprintSink {
    // TEST2 is chromaprint's default algorithm and the one AcoustID's
    // fingerprint database is built from (`fpcalc` uses it too). TEST1
    // uses a different classifier and produces fingerprints AcoustID
    // cannot match against.
    fn start(source: &AudioSource) -> Result<Self, FingerprintError> {
        let config = Configuration::preset_test2();
        let mut fingerprinter = Fingerprinter::new(&config);
        fingerprinter
            .start(source.sample_rate, source.channel_count)
            .map_err(|err| FingerprintError::UnsupportedAudioConfig(format!("{err:?}")))?;
        Ok(Self {
            fingerprinter,
            samples: Vec::with_capacity(4096 * source.channel_count.max(1) as usize),
        })
    }

    fn consume(&mut self, buffer: &GenericAudioBufferRef<'_>) {
        resize_for(&mut self.samples, buffer.samples_interleaved());
        buffer.copy_to_slice_interleaved(&mut self.samples);
        self.fingerprinter.consume(&self.samples);
    }

    fn finish(mut self) -> Vec<u32> {
        self.fingerprinter.finish();
        self.fingerprinter.fingerprint().to_vec()
    }
}

/// Encode a raw Chromaprint fingerprint (as produced by
/// `fingerprint_file`) into the compressed, base64url string AcoustID's
/// lookup API expects -- the same wire format `fpcalc`'s
/// `FINGERPRINT=` line emits.
///
/// Must use the same `Configuration` `fingerprint_file` used to
/// produce `raw`: `FingerprintCompressor` embeds the configuration's
/// algorithm id as the first byte of the compressed payload, and a
/// mismatched id makes AcoustID misinterpret the bit layout of every
/// subfingerprint that follows.
pub fn encode_fingerprint_to_base64(raw: &[u32]) -> String {
    let config = Configuration::preset_test2();
    let compressed = FingerprintCompressor::from(&config).compress(raw);
    URL_SAFE_NO_PAD.encode(compressed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    const SAMPLE_RATE: u32 = 44_100;
    const CHANNELS: u16 = 1;

    #[test]
    fn read_failures_stay_retryable_but_truncated_streams_do_not() {
        let dropped_drive = SymphoniaError::IoError(std::io::Error::from_raw_os_error(5));
        assert!(matches!(
            FingerprintError::from(dropped_drive),
            FingerprintError::Io(_)
        ));
        let truncated = SymphoniaError::IoError(std::io::ErrorKind::UnexpectedEof.into());
        assert!(matches!(
            FingerprintError::from(truncated),
            FingerprintError::Decode(_)
        ));
    }

    /// Generate `duration_seconds` of a sine wave at `frequency_hz`,
    /// quantized to signed 16-bit PCM.
    fn sine_wave_samples(frequency_hz: f32, duration_seconds: f32) -> Vec<i16> {
        let total_samples = (SAMPLE_RATE as f32 * duration_seconds) as usize;
        let mut samples = Vec::with_capacity(total_samples);
        for index in 0..total_samples {
            let time = index as f32 / SAMPLE_RATE as f32;
            let value = (2.0 * std::f32::consts::PI * frequency_hz * time).sin();
            samples.push((value * i16::MAX as f32) as i16);
        }
        samples
    }

    /// Write a mono 16-bit PCM WAV file from the given samples. Bare-
    /// minimum RIFF/WAVE header — enough for symphonia to probe.
    fn write_wav<W: Write>(writer: &mut W, samples: &[i16]) -> std::io::Result<()> {
        write_tagged_wav(writer, samples, None)
    }

    /// `title` adds a RIFF `LIST`/`INFO` chunk, WAV's tag block, ahead of
    /// the audio data.
    fn write_tagged_wav<W: Write>(
        writer: &mut W,
        samples: &[i16],
        title: Option<&str>,
    ) -> std::io::Result<()> {
        let byte_rate = SAMPLE_RATE * CHANNELS as u32 * 2;
        let data_size = (samples.len() * 2) as u32;
        let info_chunk = title.map(|title| {
            let mut value = title.as_bytes().to_vec();
            value.push(0);
            if value.len() % 2 == 1 {
                value.push(0);
            }
            let mut chunk = b"LIST".to_vec();
            chunk.extend_from_slice(&(4 + 8 + value.len() as u32).to_le_bytes());
            chunk.extend_from_slice(b"INFOINAM");
            chunk.extend_from_slice(&(value.len() as u32).to_le_bytes());
            chunk.extend_from_slice(&value);
            chunk
        });
        let info_size = info_chunk.as_ref().map_or(0, Vec::len) as u32;
        let chunk_size = 36 + info_size + data_size;

        writer.write_all(b"RIFF")?;
        writer.write_all(&chunk_size.to_le_bytes())?;
        writer.write_all(b"WAVE")?;

        writer.write_all(b"fmt ")?;
        writer.write_all(&16u32.to_le_bytes())?; // PCM fmt chunk size
        writer.write_all(&1u16.to_le_bytes())?; // PCM format
        writer.write_all(&CHANNELS.to_le_bytes())?;
        writer.write_all(&SAMPLE_RATE.to_le_bytes())?;
        writer.write_all(&byte_rate.to_le_bytes())?;
        writer.write_all(&(CHANNELS * 2).to_le_bytes())?; // block align
        writer.write_all(&16u16.to_le_bytes())?; // bits per sample

        if let Some(info_chunk) = &info_chunk {
            writer.write_all(info_chunk)?;
        }
        writer.write_all(b"data")?;
        writer.write_all(&data_size.to_le_bytes())?;
        for sample in samples {
            writer.write_all(&sample.to_le_bytes())?;
        }
        Ok(())
    }

    #[test]
    fn chromaprint_pipeline_consumes_synthetic_samples_directly() {
        // 10 seconds of a 440Hz sine wave — enough audio for Chromaprint
        // to emit a non-trivial fingerprint, no symphonia involvement.
        let samples = sine_wave_samples(440.0, 10.0);

        let config = Configuration::preset_test2();
        let mut fingerprinter = Fingerprinter::new(&config);
        fingerprinter.start(SAMPLE_RATE, CHANNELS as u32).unwrap();
        fingerprinter.consume(&samples);
        fingerprinter.finish();

        let fingerprint = fingerprinter.fingerprint();
        assert!(!fingerprint.is_empty(), "expected a non-empty fingerprint");
    }

    #[test]
    fn fingerprint_is_deterministic_for_the_same_audio() {
        let samples = sine_wave_samples(440.0, 10.0);

        let mut runs = Vec::new();
        for _ in 0..2 {
            let config = Configuration::preset_test2();
            let mut fingerprinter = Fingerprinter::new(&config);
            fingerprinter.start(SAMPLE_RATE, CHANNELS as u32).unwrap();
            fingerprinter.consume(&samples);
            fingerprinter.finish();
            runs.push(fingerprinter.fingerprint().to_vec());
        }

        assert_eq!(runs[0], runs[1], "fingerprint must be deterministic");
    }

    #[test]
    fn fingerprint_differs_between_different_audio() {
        // 660Hz, not 880Hz: chroma features are pitch-class (octave-
        // invariant) by design, and 880Hz is exactly one octave above
        // 440Hz -- the same pitch class. Under TEST2's classifier a
        // pure sine at an exact octave collapses to an identical
        // fingerprint, which is a property of chroma, not a bug. A
        // perfect fifth (660Hz) is a genuinely different pitch class
        // and asserts what this test actually means to check.
        let samples_a = sine_wave_samples(440.0, 10.0);
        let samples_b = sine_wave_samples(660.0, 10.0);

        let fingerprint = |samples: &[i16]| {
            let config = Configuration::preset_test2();
            let mut fingerprinter = Fingerprinter::new(&config);
            fingerprinter.start(SAMPLE_RATE, CHANNELS as u32).unwrap();
            fingerprinter.consume(samples);
            fingerprinter.finish();
            fingerprinter.fingerprint().to_vec()
        };

        assert_ne!(
            fingerprint(&samples_a),
            fingerprint(&samples_b),
            "different audio must produce different fingerprints"
        );
    }

    // Ruling A (see task-2-report.md): `fpcalc` is not installed on this
    // machine, so a golden string captured from it isn't available, and
    // the installed `rusty_chromaprint` 0.3.0 exposes `FingerprintCompressor`
    // (compress-only) with no public decode counterpart to round-trip
    // through. This test instead proves the encoding is well-formed and
    // stable: deterministic for the same input, and valid, unpadded
    // base64url -- the wire format AcoustID's API and `fpcalc` both use.
    #[test]
    fn encode_fingerprint_to_base64_is_deterministic_and_valid_base64url() {
        // TEST2 (id 1) is chromaprint's default and the algorithm
        // AcoustID's fingerprint database is built from. Asserting the
        // id here catches an accidental regression back to TEST1.
        assert_eq!(
            Configuration::preset_test2().id(),
            1,
            "encode_fingerprint_to_base64 must use TEST2 (id 1) for AcoustID compatibility"
        );

        // Representative raw fingerprint values -- these are opaque
        // 32-bit perceptual hashes; their specific values don't matter
        // for this test, only that encoding them is stable and produces
        // a valid base64url string.
        let raw: Vec<u32> = vec![
            0x0FCA_F446,
            0xE351_9E89,
            0xD349_4DD6,
            0x8F21_9806,
            0x9200_D530,
        ];

        let encoded_first = encode_fingerprint_to_base64(&raw);
        let encoded_second = encode_fingerprint_to_base64(&raw);

        assert!(
            !encoded_first.is_empty(),
            "encoded fingerprint must not be empty"
        );
        assert_eq!(
            encoded_first, encoded_second,
            "encoding must be deterministic for the same input"
        );

        let decoded_bytes = URL_SAFE_NO_PAD
            .decode(&encoded_first)
            .expect("encoded fingerprint must be valid base64url");
        assert!(
            !decoded_bytes.is_empty(),
            "decoded payload must not be empty"
        );
    }

    #[test]
    fn fingerprint_file_handles_synthetic_wav_end_to_end() {
        let samples = sine_wave_samples(440.0, 10.0);

        let tmpdir = std::env::temp_dir().join("crate-agent-test-fingerprint");
        std::fs::create_dir_all(&tmpdir).unwrap();
        let path = tmpdir.join("sine.wav");

        let mut file = std::fs::File::create(&path).unwrap();
        write_wav(&mut file, &samples).unwrap();
        drop(file);

        let result = fingerprint_file(&path);
        std::fs::remove_file(&path).ok();

        let fingerprint = result.expect("fingerprinting a valid WAV must succeed");
        assert!(!fingerprint.is_empty(), "expected a non-empty fingerprint");
    }

    #[test]
    fn decoded_audio_digest_follows_the_audio_not_the_tags() {
        let tmpdir = std::env::temp_dir().join(format!(
            "crate-agent-test-audio-digest-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&tmpdir).unwrap();
        let write = |name: &str, frequency_hz: f32, title: Option<&str>| {
            let path = tmpdir.join(name);
            let mut file = std::fs::File::create(&path).unwrap();
            write_tagged_wav(&mut file, &sine_wave_samples(frequency_hz, 3.0), title).unwrap();
            path
        };
        let clean = write("clean.wav", 440.0, Some("Song (Clean)"));
        let retagged = write("retagged.wav", 440.0, Some("Song (Dirty)"));
        let different = write("different.wav", 660.0, Some("Song (Clean)"));

        let digests = [&clean, &retagged, &different].map(decoded_audio_digest);
        std::fs::remove_dir_all(&tmpdir).ok();
        let [clean, retagged, different] = digests.map(|digest| digest.unwrap());

        assert_eq!(
            clean.pcm_sha256, retagged.pcm_sha256,
            "the same audio under different tags must give the same digest"
        );
        assert_ne!(
            clean.pcm_sha256, different.pcm_sha256,
            "different audio must give different digests"
        );
    }
}
