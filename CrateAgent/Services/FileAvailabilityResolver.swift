import Darwin
import Foundation

public struct FileAvailabilityResolver: Sendable {
    private let mountedVolumes: @Sendable () throws -> [URL]
    private let volumeIdentifier: @Sendable (URL) throws -> String?
    let trashDirectory: @Sendable (URL) throws -> URL

    public init() {
        self.init(mountedVolumes: Self.systemMountedVolumes, volumeIdentifier: Self.systemVolumeIdentifier)
    }

    /// `trashDirectory` names the Trash that would hold a file, by default the user's.
    init(mountedVolumes: @escaping @Sendable () throws -> [URL] = Self.systemMountedVolumes,
         volumeIdentifier: @escaping @Sendable (URL) throws -> String? = Self.systemVolumeIdentifier,
         trashDirectory: @escaping @Sendable (URL) throws -> URL = Self.systemTrashDirectory)
    {
        self.mountedVolumes = mountedVolumes
        self.volumeIdentifier = volumeIdentifier
        self.trashDirectory = trashDirectory
    }

    static let systemMountedVolumes: @Sendable () throws -> [URL] = {
        guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey]) else {
            throw CocoaError(.fileReadUnknown)
        }
        return volumes
    }

    static let systemVolumeIdentifier: @Sendable (URL) throws -> String? = { volume in
        try volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    static let systemTrashDirectory: @Sendable (URL) throws -> URL = { fileURL in
        try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: fileURL, create: false)
    }

    public func inspect(path: String, volumeID: String) throws -> FileAvailability {
        let manager = FileManager.default
        let volumes = try mountedVolumes()
        var volumeIsOnline = false
        for volume in volumes {
            guard let candidateIdentifier = try? volumeIdentifier(volume) else { continue }
            if candidateIdentifier == volumeID {
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
            let trashURL = try trashDirectory(fileURL)
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
