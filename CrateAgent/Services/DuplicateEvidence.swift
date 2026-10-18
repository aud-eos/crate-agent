import Foundation
import GRDB

/// What a duplicate check knows about one file, read from its digest cache
/// only while the cached basis still matches the file.
public enum DuplicateEvidence: Hashable, Sendable {
    case pending
    /// `retryable` failures (I/O, permission, a file changing mid-check) are
    /// retried by the next check; a deterministic decode failure is not.
    case unreadable(reason: String, retryable: Bool)
    case decoded(DecodedAudio)
    /// SHA-256 of every byte of the file.
    case content(Data)

    public struct DecodedAudio: Hashable, Sendable {
        public let format: String
        public let pcmDigest: Data
        public let fullFingerprintDigest: Data
        public let durationSeconds: Double

        init(format: String, pcmDigest: Data, fullFingerprintDigest: Data, durationSeconds: Double) {
            self.format = format
            self.pcmDigest = pcmDigest
            self.fullFingerprintDigest = fullFingerprintDigest
            self.durationSeconds = durationSeconds
        }

        /// Nil when the decoder reported no sample rate, so no duration.
        init?(_ digest: DecodedAudioDigest) {
            guard digest.sampleRate > 0 else { return nil }
            self.init(format: digest.format, pcmDigest: digest.pcmSha256, fullFingerprintDigest: digest.fullFingerprintSha256,
                      durationSeconds: Double(digest.frameCount) / Double(digest.sampleRate))
        }
    }

    public enum Relation: Sendable, Equatable {
        /// Identical bytes or decoded PCM: the only basis for pre-selecting cleanup.
        case identical
        /// Different PCM (another format, or another encoding of one format)
        /// with an identical full-length fingerprint and durations within
        /// half a second. Clean and Dirty edits can pass this, so it is never
        /// proof: cleanup needs an explicit choice.
        case fingerprintMatch
        case different
    }

    static let fingerprintMatchDurationToleranceSeconds = 0.5

    static func relation(_ lhs: Self, _ rhs: Self) -> Relation {
        switch (lhs, rhs) {
        case let (.content(lhsDigest), .content(rhsDigest)):
            return lhsDigest == rhsDigest ? .identical : .different
        case let (.decoded(lhsAudio), .decoded(rhsAudio)):
            if lhsAudio.pcmDigest == rhsAudio.pcmDigest {
                return .identical
            }
            if lhsAudio.fullFingerprintDigest == rhsAudio.fullFingerprintDigest,
               abs(lhsAudio.durationSeconds - rhsAudio.durationSeconds) <= fingerprintMatchDurationToleranceSeconds
            {
                return .fingerprintMatch
            }
            return .different
        default:
            return .different
        }
    }

    var isPending: Bool {
        self == .pending
    }

    var decodedFormat: String? {
        guard case let .decoded(audio) = self else { return nil }
        return audio.format
    }

    var isReady: Bool {
        switch self {
        case .decoded, .content: true
        case .pending, .unreadable: false
        }
    }
}

/// Which digest a duplicate mode confirms with.
enum DigestKind: String, Codable, Sendable {
    /// Byte-level groups share only a size and a first/last 1 MB hash, so
    /// they are confirmed by a digest of every byte.
    case content
    /// Perceptual groups are confirmed by decoded audio.
    case audio

    var table: String {
        switch self {
        case .content: "file_content_digests"
        case .audio: "file_audio_digests"
        }
    }
}

extension DuplicateFinder.Mode {
    var digestKind: DigestKind {
        switch self {
        case .byteLevel: .content
        case .perceptual: .audio
        }
    }
}

/// What the cleanup boundary requires of a target relative to its keeper.
struct DuplicateEvidenceRequirement: Codable, Equatable, Sendable {
    let kind: DigestKind
    /// The user explicitly selected this file after listening.
    let allowsFingerprintMatch: Bool
}

/// The file identity a digest was computed from: the `files` row's size,
/// mtime and inode, plus the nanosecond mtime and the ctime seen on disk.
/// PR 206 adds a shared `hasSameModificationTime` predicate; once it lands,
/// `matches(_:)` should use it instead of comparing exactly.
struct DigestBasis: Equatable, Sendable {
    let fileSize: Int64
    let mtime: Int64
    let inode: Int64
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(fileSize: Int64, mtime: Int64, inode: Int64, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int) {
        self.fileSize = fileSize
        self.mtime = mtime
        self.inode = inode
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
    }

    init(indexed candidate: DigestCandidate, live: SeratoSourceIdentity) {
        self.init(fileSize: candidate.fileSize, mtime: candidate.mtime, inode: candidate.inode,
                  modifiedNanoseconds: live.modifiedNanoseconds, changedSeconds: live.changedSeconds, changedNanoseconds: live.changedNanoseconds)
    }

    func matches(_ live: SeratoSourceIdentity) -> Bool {
        live.size == fileSize && Int64(live.modifiedSeconds) == mtime && Int64(bitPattern: live.inode) == inode
            && live.modifiedNanoseconds == modifiedNanoseconds && live.changedSeconds == changedSeconds
            && live.changedNanoseconds == changedNanoseconds
    }
}

/// A duplicate-group member as indexed, awaiting a digest.
struct DigestCandidate: Sendable {
    let fileID: Int64
    let path: String
    let fileSize: Int64
    let mtime: Int64
    let inode: Int64
}

struct DigestResult: Sendable {
    let fileID: Int64
    let basis: DigestBasis
    let evidence: DuplicateEvidence
}

enum DuplicateCheckError: LocalizedError, Equatable {
    case notConfirmed(path: String)
    case inconsistentCacheRow(fileID: Int64)

    var errorDescription: String? {
        switch self {
        case let .notConfirmed(path):
            "\((path as NSString).lastPathComponent) was not moved to Trash: it is no longer confirmed to match the keeper. Rescan duplicates to check it again."
        case let .inconsistentCacheRow(fileID):
            "The duplicate check for file id \(fileID) is incomplete. Rescan duplicates to check it again."
        }
    }
}

enum DuplicateDigestStore {
    /// Joins each file to its digest row while the indexed size, mtime and
    /// inode match; the nanosecond mtime and ctime are compared with the
    /// live file by `DuplicateEvidenceVerifier` and the cleanup boundary.
    static func freshJoinSQL(_ kind: DigestKind, as alias: String = "digest") -> String {
        """
        LEFT JOIN \(kind.table) AS \(alias) ON \(alias).file_id = files.id
          AND \(alias).file_size = files.file_size AND \(alias).mtime = files.mtime AND \(alias).inode = files.inode
        """
    }

    /// The digest column that proves two files `.identical` under `kind`.
    static func confirmingDigestColumn(_ kind: DigestKind, of alias: String) -> String {
        switch kind {
        case .content: "\(alias).content_sha256"
        case .audio: "\(alias).pcm_sha256"
        }
    }

    static func columnsSQL(_ kind: DigestKind) -> String {
        let common = """
        digest.file_id AS digest_file_id, digest.failure AS digest_failure, digest.retryable AS digest_retryable,
        digest.file_size AS digest_file_size, digest.mtime AS digest_mtime, digest.inode AS digest_inode,
        digest.modified_nanoseconds AS digest_modified_nanoseconds, digest.changed_seconds AS digest_changed_seconds,
        digest.changed_nanoseconds AS digest_changed_nanoseconds
        """
        switch kind {
        case .content:
            return common + ", digest.content_sha256 AS digest_content_sha256"
        case .audio:
            return common + """
            , digest.format AS digest_format, digest.pcm_sha256 AS digest_pcm_sha256,
            digest.full_fingerprint_sha256 AS digest_full_fingerprint_sha256, digest.duration_seconds AS digest_duration_seconds
            """
        }
    }

    static func evidence(from row: Row, kind: DigestKind) throws -> DuplicateEvidence {
        guard let fileID: Int64 = row["digest_file_id"] else { return .pending }
        if let failure: String = row["digest_failure"] {
            return .unreadable(reason: failure, retryable: row["digest_retryable"])
        }
        switch kind {
        case .content:
            guard let digest: Data = row["digest_content_sha256"] else { throw DuplicateCheckError.inconsistentCacheRow(fileID: fileID) }
            return .content(digest)
        case .audio:
            guard let format: String = row["digest_format"], let pcmDigest: Data = row["digest_pcm_sha256"],
                  let fullFingerprintDigest: Data = row["digest_full_fingerprint_sha256"],
                  let durationSeconds: Double = row["digest_duration_seconds"]
            else { throw DuplicateCheckError.inconsistentCacheRow(fileID: fileID) }
            return .decoded(.init(format: format, pcmDigest: pcmDigest, fullFingerprintDigest: fullFingerprintDigest,
                                  durationSeconds: durationSeconds))
        }
    }

    static func basis(from row: Row) -> DigestBasis? {
        guard let fileSize: Int64 = row["digest_file_size"] else { return nil }
        return DigestBasis(fileSize: fileSize, mtime: row["digest_mtime"], inode: row["digest_inode"],
                           modifiedNanoseconds: row["digest_modified_nanoseconds"], changedSeconds: row["digest_changed_seconds"],
                           changedNanoseconds: row["digest_changed_nanoseconds"])
    }

    /// Stores each result only while its file still has the indexed size,
    /// mtime and inode it was computed for; a file changed since then is
    /// checked again later.
    static func save(_ results: [DigestResult], kind: DigestKind, in database: Database) throws {
        for result in results {
            let columns: String
            let values: [(any DatabaseValueConvertible)?]
            switch (result.evidence, kind) {
            case (.pending, _):
                continue
            case let (.unreadable(reason, retryable), _):
                columns = "failure, retryable"
                values = [reason, retryable]
            case let (.content(digest), .content):
                columns = "content_sha256"
                values = [digest]
            case let (.decoded(audio), .audio):
                columns = "format, pcm_sha256, full_fingerprint_sha256, duration_seconds"
                values = [audio.format, audio.pcmDigest, audio.fullFingerprintDigest, audio.durationSeconds]
            case (.content, .audio), (.decoded, .content):
                throw DuplicateCheckError.inconsistentCacheRow(fileID: result.fileID)
            }
            let basis = result.basis
            try database.execute(sql: """
                INSERT OR REPLACE INTO \(kind.table)
                    (file_id, file_size, mtime, inode, modified_nanoseconds, changed_seconds, changed_nanoseconds, \(columns))
                SELECT id, file_size, mtime, inode, ?, ?, ?, \(databaseQuestionMarks(count: values.count)) FROM files
                WHERE id = ? AND file_size = ? AND mtime = ? AND inode = ?
                """, arguments: StatementArguments([basis.modifiedNanoseconds, basis.changedSeconds, basis.changedNanoseconds])
                    + StatementArguments(values) + StatementArguments([result.fileID, basis.fileSize, basis.mtime, basis.inode]))
        }
    }

    static func delete(fileIDs: [Int64], kind: DigestKind, in database: Database) throws {
        guard !fileIDs.isEmpty else { return }
        try database.execute(sql: "DELETE FROM \(kind.table) WHERE file_id IN (\(databaseQuestionMarks(count: fileIDs.count)))",
                             arguments: StatementArguments(fileIDs))
    }

    /// The cleanup boundary's recheck: both files' cached evidence must have
    /// been computed for exactly the identities the cleanup was authorized
    /// with, the live files must still carry that basis, and the evidence
    /// must satisfy `requirement`.
    static func requireConfirmed(target: FileActionAuthority, keeper: FileActionAuthority, requirement: DuplicateEvidenceRequirement,
                                 in database: Database) throws
    {
        func evidence(_ authority: FileActionAuthority) throws -> DuplicateEvidence {
            let identity = authority.identity
            guard let row = try Row.fetchOne(database, sql: """
            SELECT \(columnsSQL(requirement.kind)) FROM \(requirement.kind.table) AS digest
            WHERE digest.file_id = ? AND digest.file_size = ? AND digest.mtime = ? AND digest.inode = ?
            """, arguments: [authority.token.fileId, identity.fileSize, identity.mtime, identity.inode]),
            let basis = basis(from: row),
            let live = try? AudioFileReadIdentity.read(at: identity.path).target, basis.matches(live)
            else { return .pending }
            return try self.evidence(from: row, kind: requirement.kind)
        }
        switch try DuplicateEvidence.relation(evidence(target), evidence(keeper)) {
        case .identical: return
        case .fingerprintMatch where requirement.allowsFingerprintMatch: return
        case .fingerprintMatch, .different: throw DuplicateCheckError.notConfirmed(path: target.identity.path)
        }
    }
}
