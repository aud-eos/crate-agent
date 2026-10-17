import GRDB

public enum LibraryMembership: String, Codable, DatabaseValueConvertible, Hashable, Sendable {
    case legacyUnverified, active, pendingImport, retired
}

public enum FileAvailability: String, Codable, DatabaseValueConvertible, Hashable, Sendable {
    case unknown, available, missing, trashed, offline, inaccessible
}

public struct FileLibraryState: Codable, Equatable, Sendable {
    public let membership: LibraryMembership
    public let availability: FileAvailability
    public let libraryID: String?
    public let retiredAt: Int64?
}

public struct SetFileLibraryStatePayload: Codable, Sendable {
    public let fileId: Int64
    public let expectedRevision: Int64
    public let state: FileLibraryState
    public var observedReadditionAfterOwnedRemoval: Bool? = nil
    /// The verified native Trash item for a `.trashed` state; nil keeps the recorded one.
    public var trashLocation: FileMetadata? = nil
}
