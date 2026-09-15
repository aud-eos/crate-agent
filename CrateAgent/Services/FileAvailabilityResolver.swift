import Darwin
import Foundation

public struct FileAvailabilityResolver: Sendable {
    public init() {}

    public func inspect(path: String, volumeID: String) throws -> FileAvailability {
        let manager = FileManager.default
        guard let volumes = manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var volumeIsOnline = false
        for volume in volumes {
            if try volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == volumeID {
                volumeIsOnline = true
                break
            }
        }
        guard volumeIsOnline else { return .offline }
        var metadata = stat()
        guard stat(path, &metadata) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case EACCES, EPERM: return .inaccessible
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let fileURL = URL(fileURLWithPath: path)
        do {
            let trashURL = try manager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: fileURL, create: false)
            var relationship = FileManager.URLRelationship.other
            try manager.getRelationship(&relationship, ofDirectoryAt: trashURL, toItemAt: fileURL)
            if relationship == .contains || relationship == .same {
                return .trashed
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // A volume without a Trash directory cannot contain this existing file in Trash.
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .inaccessible
        }
        guard access(path, R_OK) == 0 else { return .inaccessible }
        return .available
    }
}
