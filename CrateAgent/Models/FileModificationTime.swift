import Foundation

/// A recorded modification time: whole seconds since the epoch and, since migration 018,
/// the subsecond part (`mtimeNanoseconds`, nil when it was recorded earlier).
protocol FileModificationTimed {
    var mtime: Int64 { get }
    var mtimeNanoseconds: Int64? { get }
}

extension FileModificationTimed {
    /// The one test for "same modification time" in identity decisions. Seconds always
    /// compare; nanoseconds compare when both sides recorded them, so a legacy identity still
    /// matches its unchanged file. That leniency makes the relation non-transitive: a legacy
    /// time matches every subsecond time within its second.
    func hasSameModificationTime(as other: some FileModificationTimed) -> Bool {
        guard mtime == other.mtime else { return false }
        guard let mtimeNanoseconds, let otherNanoseconds = other.mtimeNanoseconds else { return true }
        return mtimeNanoseconds == otherNanoseconds
    }
}

extension FileMetadata: FileModificationTimed {}
extension FileRecord: FileModificationTimed {}
extension FileFreshnessSnapshot: FileModificationTimed {}

/// The modification time a `stat` reports, for comparison with a recorded one.
struct StatModificationTime: FileModificationTimed {
    let mtime: Int64
    let mtimeNanoseconds: Int64?

    init(_ status: stat) {
        mtime = Int64(status.st_mtimespec.tv_sec)
        mtimeNanoseconds = Int64(status.st_mtimespec.tv_nsec)
    }
}
