import Foundation

/// A path's exact UTF-8 bytes as a hash key. Equality is byte equality, so NFC and NFD
/// spellings stay distinct. Foundation's `Data` hashes only a short prefix, and paths
/// under one library root share long prefixes, so `Data` keys collide into one bucket
/// and make large path sets quadratic (#218).
struct PathBytes: Hashable, Sendable {
    let bytes: Data

    init(_ path: String) {
        bytes = Data(path.utf8)
    }

    init(bytes: Data) {
        self.bytes = bytes
    }

    func hash(into hasher: inout Hasher) {
        bytes.withUnsafeBytes { buffer in hasher.combine(bytes: buffer) }
    }
}
