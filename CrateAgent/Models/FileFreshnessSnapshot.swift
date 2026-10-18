import Foundation

/// The on-disk identity that decides whether work derived from a file still describes it:
/// a stored fingerprint (its basis), a reviewed match candidate (its expected identity) and
/// a redo (the row's identity). Size in bytes; `mtime` in whole seconds since the epoch;
/// `mtimeNanoseconds` is the subsecond part (0..<1_000_000_000).
///
/// Subsecond time catches a same-length edit within one second, and the inode catches an
/// atomic replacement. Neither detects a deliberate edit that restores the original size,
/// timestamp and inode; content is not compared.
public struct FileFreshnessSnapshot: Equatable, Sendable {
    public let fileSize: Int64
    /// Nil when it was never recorded (fingerprint bases and payloads before migration 018).
    public let inode: Int64?
    public let mtime: Int64
    /// Nil when it was never recorded (rows, bases and payloads before migration 018).
    public let mtimeNanoseconds: Int64?

    public init(fileSize: Int64, inode: Int64?, mtime: Int64, mtimeNanoseconds: Int64?) {
        self.fileSize = fileSize
        self.inode = inode
        self.mtime = mtime
        self.mtimeNanoseconds = mtimeNanoseconds
    }

    public init(_ metadata: FileMetadata) {
        self.init(fileSize: metadata.fileSize, inode: metadata.inode, mtime: metadata.mtime, mtimeNanoseconds: metadata.mtimeNanoseconds)
    }

    /// Whether `current`, a live stat, proves this recorded identity still describes the file.
    /// A field that was never recorded proves nothing, so a legacy identity is never confirmed
    /// and the work derived from it is redone once.
    public func isConfirmed(by current: FileFreshnessSnapshot) -> Bool {
        inode != nil && mtimeNanoseconds != nil && describesSameFile(as: current)
    }

    /// Whether a live stat is still the file this identity describes, under the shared
    /// identity rule: a legacy time without nanoseconds matches on whole seconds.
    func describesSameFile(as current: FileFreshnessSnapshot) -> Bool {
        fileSize == current.fileSize && inode == current.inode && hasSameModificationTime(as: current)
    }
}
