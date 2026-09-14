import CryptoKit
import Foundation

/// Transaction ownership includes all bytes; the library's sampled hash cannot
/// authorize deletion of an audio file whose unsampled region was edited.
struct OwnedAudioIdentity: Sendable, Equatable {
    let metadata: FileMetadata
    let change: SeratoSourceIdentity
    let digest: Data

    static func read(at path: String) throws -> Self {
        let url = URL(fileURLWithPath: path)
        let before = try SeratoSourceIdentity.read(url)
        let handle = try FileHandle(forReadingFrom: url)
        let result = Result { () throws -> Data in
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                hasher.update(data: bytes)
            }
            return Data(hasher.finalize())
        }
        try handle.close()
        let digest = try result.get()
        let metadata = try FileMetadataCollector.collectVerified(at: path)
        guard try SeratoSourceIdentity.read(url) == before else { throw SeratoMembershipSnapshotError.sourceChanged }
        return Self(metadata: metadata, change: before, digest: digest)
    }

    func requireUnchanged(at path: String) throws {
        guard try Self.read(at: path) == self else { throw SeratoMembershipSnapshotError.sourceChanged }
    }
}
