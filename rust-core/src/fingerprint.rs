// Audio fingerprinting via Chromaprint.
//
// Decodes audio with `symphonia` (broad codec support — MP3, FLAC, WAV,
// AIFF, ALAC, AAC) and feeds PCM samples to `rusty_chromaprint` to
// produce a perceptual fingerprint stable across re-encodings and
// bitrate changes.
//
// The Swift FingerprintWorker drives this in a worker pool sized to
// CPU cores − 2; this module exposes a single-threaded function per
// file and lets the caller manage concurrency.
//
// Implementations land with the fingerprinting pipeline in SP-1.
