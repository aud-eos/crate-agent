import Foundation

/// Bridges the stored Chromaprint fingerprint blob (`files.chromaprint_fingerprint`,
/// a little-endian `[UInt32]` byte serialization — see Rule 4) to the
/// AcoustID-compatible base64 string the MusicBrainz auto-tagger sends
/// to the lookup API.
///
/// `serialize`/`deserialize` are the shared byte-encoding mechanic used
/// by both `FingerprintWorker` (writing fresh fingerprints) and this
/// encoder (reading them back for lookup) — one definition, not two.
public enum FingerprintEncoder {
    /// Little-endian byte-serialization of Chromaprint's `[UInt32]`.
    /// Length-prefix isn't needed — the blob's length divided by 4
    /// gives the count back, and the column is opaque to SQLite.
    public static func serialize(_ hashes: [UInt32]) -> Data {
        var data = Data(capacity: hashes.count * 4)
        for hash in hashes {
            var littleEndian = hash.littleEndian
            withUnsafeBytes(of: &littleEndian) { rawBuffer in
                data.append(contentsOf: rawBuffer)
            }
        }
        return data
    }

    public static func deserialize(_ bytes: Data) -> [UInt32] {
        guard bytes.count % 4 == 0 else { return [] }
        var hashes: [UInt32] = []
        hashes.reserveCapacity(bytes.count / 4)
        bytes.withUnsafeBytes { rawBuffer in
            let typedBuffer = rawBuffer.bindMemory(to: UInt32.self)
            for hash in typedBuffer {
                hashes.append(UInt32(littleEndian: hash))
            }
        }
        return hashes
    }

    /// Decodes a stored fingerprint blob and re-encodes it as the
    /// AcoustID-compatible base64 string, via the Rust `encodeFingerprint`
    /// FFI (chromaprint TEST2). Returns `nil` for empty or corrupt bytes
    /// — there's nothing to look up a match with.
    public static func base64(fromStoredBytes bytes: Data) -> String? {
        let hashes = deserialize(bytes)
        guard !hashes.isEmpty else { return nil }
        return encodeFingerprint(raw: hashes)
    }
}
