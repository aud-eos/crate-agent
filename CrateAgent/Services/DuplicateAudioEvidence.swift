import Foundation
import GRDB

/// What the decoded-audio check knows about one file, read from
/// `file_audio_digests` only while the row's size, mtime and inode still
/// match the file's.
public enum DuplicateAudioEvidence: Hashable, Sendable {
    case pending
    case unreadable(String)
    case decoded(DecodedAudio)

    public struct DecodedAudio: Hashable, Sendable {
        public let format: String
        public let pcmDigest: Data
        public let fullFingerprintDigest: Data
        public let durationSeconds: Double
    }

    public enum Relation: Sendable, Equatable {
        /// Identical decoded PCM: the only basis for pre-selecting cleanup.
        case identical
        /// Different PCM (another format, or another encoding of one format)
        /// with an identical full-length fingerprint and durations within
        /// half a second. Clean and Dirty edits can pass this, so it is never
        /// proof: cleanup needs an explicit choice.
        case fingerprintMatch
        case different
    }

    static let fingerprintMatchDurationToleranceSeconds = 0.5

    static func relation(_ lhs: DecodedAudio, _ rhs: DecodedAudio) -> Relation {
        if lhs.pcmDigest == rhs.pcmDigest {
            return .identical
        }
        if lhs.fullFingerprintDigest == rhs.fullFingerprintDigest,
           abs(lhs.durationSeconds - rhs.durationSeconds) <= fingerprintMatchDurationToleranceSeconds
        {
            return .fingerprintMatch
        }
        return .different
    }
}

/// What the cleanup boundary requires of a target's audio relative to its
/// keeper.
enum DuplicateAudioRequirement: Sendable, Equatable {
    /// Byte-level cleanup, which matches on content hashes.
    case none
    case identical
    /// The user explicitly selected this file in a group needing listening.
    case identicalOrExplicitFingerprintMatch
}

/// The size, mtime and inode a digest was computed from.
struct AudioDigestBasis: Equatable, Sendable {
    let fileSize: Int64
    let mtime: Int64
    let inode: Int64

    init(fileSize: Int64, mtime: Int64, inode: Int64) {
        self.fileSize = fileSize
        self.mtime = mtime
        self.inode = inode
    }

    init(_ identity: FileMetadata) {
        self.init(fileSize: identity.fileSize, mtime: identity.mtime, inode: identity.inode)
    }
}

struct AudioDigestResult: Sendable {
    let fileID: Int64
    let basis: AudioDigestBasis
    let evidence: DuplicateAudioEvidence
}

enum DuplicateAudioCheckError: LocalizedError, Equatable {
    case notConfirmed(path: String)
    case inconsistentCacheRow(fileID: Int64)

    var errorDescription: String? {
        switch self {
        case let .notConfirmed(path):
            "\((path as NSString).lastPathComponent) was not moved to Trash: its audio is no longer confirmed to match the keeper. Rescan duplicates to check it again."
        case let .inconsistentCacheRow(fileID):
            "The audio check for file id \(fileID) is incomplete. Rescan duplicates to check it again."
        }
    }
}

enum AudioDigestStore {
    /// Joins each file to its digest row only while the basis is current.
    static let freshJoinSQL = """
    LEFT JOIN file_audio_digests AS audio ON audio.file_id = files.id
      AND audio.file_size = files.file_size AND audio.mtime = files.mtime AND audio.inode = files.inode
    """

    static let columnsSQL = """
    audio.file_id AS audio_file_id, audio.format AS audio_format, audio.pcm_sha256 AS audio_pcm_sha256,
    audio.full_fingerprint_sha256 AS audio_full_fingerprint_sha256, audio.duration_seconds AS audio_duration_seconds,
    audio.failure AS audio_failure
    """

    static func evidence(from row: Row) throws -> DuplicateAudioEvidence {
        guard let fileID: Int64 = row["audio_file_id"] else { return .pending }
        if let failure: String = row["audio_failure"] {
            return .unreadable(failure)
        }
        guard let format: String = row["audio_format"], let pcmDigest: Data = row["audio_pcm_sha256"],
              let fullFingerprintDigest: Data = row["audio_full_fingerprint_sha256"],
              let durationSeconds: Double = row["audio_duration_seconds"]
        else { throw DuplicateAudioCheckError.inconsistentCacheRow(fileID: fileID) }
        return .decoded(.init(format: format, pcmDigest: pcmDigest, fullFingerprintDigest: fullFingerprintDigest, durationSeconds: durationSeconds))
    }

    /// Stores each result only while its file still has the basis it was
    /// computed for; a file changed since then is checked again later.
    static func save(_ results: [AudioDigestResult], in database: Database) throws {
        for result in results {
            var format: String?
            var pcmDigest: Data?
            var fullFingerprintDigest: Data?
            var durationSeconds: Double?
            var failure: String?
            switch result.evidence {
            case .pending:
                continue
            case let .unreadable(reason):
                failure = reason
            case let .decoded(audio):
                format = audio.format
                pcmDigest = audio.pcmDigest
                fullFingerprintDigest = audio.fullFingerprintDigest
                durationSeconds = audio.durationSeconds
            }
            try database.execute(sql: """
            INSERT OR REPLACE INTO file_audio_digests
                (file_id, file_size, mtime, inode, format, pcm_sha256, full_fingerprint_sha256, duration_seconds, failure)
            SELECT id, file_size, mtime, inode, ?, ?, ?, ?, ? FROM files
            WHERE id = ? AND file_size = ? AND mtime = ? AND inode = ?
            """, arguments: [format, pcmDigest, fullFingerprintDigest, durationSeconds, failure,
                             result.fileID, result.basis.fileSize, result.basis.mtime, result.basis.inode])
        }
    }

    /// The cleanup boundary's recheck: both files' cached evidence must have
    /// been computed for exactly the identities the cleanup was authorized
    /// with, and must still satisfy `requirement`.
    static func requireSameAudio(target: FileActionAuthority, keeper: FileActionAuthority, requirement: DuplicateAudioRequirement,
                                 in database: Database) throws
    {
        guard requirement != .none else { return }
        func decoded(_ authority: FileActionAuthority) throws -> DuplicateAudioEvidence.DecodedAudio? {
            let basis = AudioDigestBasis(authority.identity)
            guard let row = try Row.fetchOne(database, sql: """
            SELECT \(columnsSQL) FROM file_audio_digests AS audio
            WHERE audio.file_id = ? AND audio.file_size = ? AND audio.mtime = ? AND audio.inode = ?
            """, arguments: [authority.token.fileId, basis.fileSize, basis.mtime, basis.inode]),
            case let .decoded(audio) = try evidence(from: row) else { return nil }
            return audio
        }
        guard let targetAudio = try decoded(target), let keeperAudio = try decoded(keeper) else {
            throw DuplicateAudioCheckError.notConfirmed(path: target.identity.path)
        }
        switch (DuplicateAudioEvidence.relation(targetAudio, keeperAudio), requirement) {
        case (.identical, _), (.fingerprintMatch, .identicalOrExplicitFingerprintMatch): return
        default: throw DuplicateAudioCheckError.notConfirmed(path: target.identity.path)
        }
    }
}
