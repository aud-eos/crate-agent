@testable import CrateAgent
import Foundation

extension DuplicateFinder.DuplicateGroup where File == FileRecord {
    /// A byte-level group as the panel offers it once every file's full
    /// contents have been digested: the digests are really computed, so the
    /// cleanup boundary's recheck sees the same evidence a scan would.
    static func confirmedByteLevel(_ key: String, files: [FileRecord], in database: LibraryDatabase) async throws -> Self {
        let candidates = files.compactMap { file in
            file.id.map { identifier in
                DigestCandidate(fileID: identifier, path: file.path, fileSize: file.fileSize, mtime: file.mtime, inode: file.inode)
            }
        }
        try await DuplicateEvidenceVerifier(database: database).verify(candidates, kind: .content)
        return Self(groupKey: key, mode: .byteLevel, files: files, check: .confirmed)
    }
}

extension DuplicateEvidenceRequirement {
    static let identicalContent = Self(kind: .content, allowsFingerprintMatch: false)
}
