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
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
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

/// Decode an audio file and return its Chromaprint fingerprint.
///
/// The fingerprint is a sequence of 32-bit hashes covering the audio's
/// perceptual signature. Stable across re-encoding (WAV ↔ MP3 320, etc.)
/// within Chromaprint's perceptual tolerance.
pub fn fingerprint_file(path: impl AsRef<Path>) -> Result<Vec<u32>, FingerprintError> {
    let path_ref = path.as_ref();
    let file = File::open(path_ref)?;
    let media_source = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path_ref.extension().and_then(|ext| ext.to_str()) {
        hint.with_extension(ext);
    }

    let mut format = symphonia::default::get_probe()
        .probe(
            &hint,
            media_source,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|err| FingerprintError::Decode(err.to_string()))?;

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

    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(codec_params, &AudioDecoderOptions::default())
        .map_err(|err| FingerprintError::Decode(err.to_string()))?;

    // TEST2 is chromaprint's default algorithm and the one AcoustID's
    // fingerprint database is built from (`fpcalc` uses it too). TEST1
    // uses a different classifier and produces fingerprints AcoustID
    // cannot match against.
    let config = Configuration::preset_test2();
    let mut fingerprinter = Fingerprinter::new(&config);
    fingerprinter
        .start(sample_rate, channel_count)
        .map_err(|err| FingerprintError::UnsupportedAudioConfig(format!("{err:?}")))?;

    // Pre-size to one packet's worth of stereo MP3 samples (1152
    // frames × 2 channels = 2304). Real values vary by codec but
    // this avoids the resize-then-zero-fill-then-overwrite cycle
    // on the first ~38 packets of a typical track. The buffer
    // grows on demand if a codec hands us larger packets.
    let mut samples: Vec<i16> = Vec::with_capacity(4096 * channel_count.max(1) as usize);
    let max_frames = sample_rate as u64 * FINGERPRINT_MAX_DURATION_SECONDS;
    let mut frames_consumed: u64 = 0;

    while let Some(packet) = format
        .next_packet()
        .map_err(|err| FingerprintError::Decode(err.to_string()))?
    {
        if packet.track_id != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(audio_buf) => {
                let interleaved = audio_buf.samples_interleaved();
                // Only grow — never shrink — to avoid pointless
                // dealloc / realloc cycles when packet sizes vary.
                // copy_to_slice_interleaved overwrites every byte,
                // so the zero-fill of `resize` is wasted work.
                if samples.len() < interleaved {
                    samples.resize(interleaved, 0i16);
                } else {
                    samples.truncate(interleaved);
                }
                audio_buf.copy_to_slice_interleaved(&mut samples);
                fingerprinter.consume(&samples);
                // Track time consumed by counting frames (interleaved
                // sample count / channel count). Once we've fed
                // Chromaprint 120 seconds of audio, the hash has
                // converged; reading more wastes decode cycles.
                frames_consumed += (interleaved as u64) / channel_count.max(1) as u64;
                if frames_consumed >= max_frames {
                    break;
                }
            }
            // Skip individual packets that fail to decode — a single
            // bad frame should not abort fingerprinting an entire track.
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(other) => return Err(FingerprintError::Decode(other.to_string())),
        };
    }

    fingerprinter.finish();
    Ok(fingerprinter.fingerprint().to_vec())
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
        let byte_rate = SAMPLE_RATE * CHANNELS as u32 * 2;
        let data_size = (samples.len() * 2) as u32;
        let chunk_size = 36 + data_size;

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
}
