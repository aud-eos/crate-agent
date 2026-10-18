import Foundation

/// Sets a file's modification time to the nanosecond, as a same-second edit leaves it.
func setModificationTime(of path: String, seconds: Int, nanoseconds: Int) throws {
    var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
    guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Overwrites a file's bytes in place, keeping its inode.
func overwriteInPlace(_ path: String, with data: Data) throws {
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.write(contentsOf: data)
    try handle.close()
}
