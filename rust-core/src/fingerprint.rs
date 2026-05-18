// Audio fingerprinting via Chromaprint.
//
// Decodes audio with `symphonia` (broad codec support — MP3, FLAC, WAV,
// AIFF, ALAC, AAC, OGG Vorbis) and feeds the resulting PCM samples to
// `rusty_chromaprint` to produce a perceptual fingerprint stable across
// re-encodings and bitrate changes.
//
// The Swift FingerprintWorker drives this in a worker pool sized to
// CPU cores − 2; this module exposes a single-threaded function per
// file and lets the caller manage concurrency.

use std::fs::File;
use std::path::Path;

use rusty_chromaprint::{Configuration, Fingerprinter};
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
        .probe(&hint, media_source, FormatOptions::default(), MetadataOptions::default())
        .map_err(|err| FingerprintError::Decode(err.to_string()))?;

    let track = format.default_track(TrackType::Audio).ok_or(FingerprintError::NoAudioTracks)?;
    let track_id = track.id;

    let codec_params = track
        .codec_params
        .as_ref()
        .ok_or(FingerprintError::MissingCodecParameter("codec_params"))?
        .audio()
        .ok_or(FingerprintError::MissingCodecParameter("audio_codec_params"))?;

    let sample_rate =
        codec_params.sample_rate.ok_or(FingerprintError::MissingCodecParameter("sample_rate"))?;
    let channel_count = codec_params
        .channels
        .as_ref()
        .ok_or(FingerprintError::MissingCodecParameter("channels"))?
        .count() as u32;

    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(codec_params, &AudioDecoderOptions::default())
        .map_err(|err| FingerprintError::Decode(err.to_string()))?;

    let config = Configuration::preset_test1();
    let mut fingerprinter = Fingerprinter::new(&config);
    fingerprinter
        .start(sample_rate, channel_count)
        .map_err(|err| FingerprintError::UnsupportedAudioConfig(format!("{err:?}")))?;

    let mut samples: Vec<i16> = Vec::new();

    while let Some(packet) =
        format.next_packet().map_err(|err| FingerprintError::Decode(err.to_string()))?
    {
        if packet.track_id != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(audio_buf) => {
                samples.resize(audio_buf.samples_interleaved(), 0i16);
                audio_buf.copy_to_slice_interleaved(&mut samples);
                fingerprinter.consume(&samples);
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

        let config = Configuration::preset_test1();
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
            let config = Configuration::preset_test1();
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
        let samples_a = sine_wave_samples(440.0, 10.0);
        let samples_b = sine_wave_samples(880.0, 10.0);

        let fingerprint = |samples: &[i16]| {
            let config = Configuration::preset_test1();
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
