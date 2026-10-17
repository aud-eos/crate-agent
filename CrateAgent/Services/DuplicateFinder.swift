import CryptoKit
import Foundation
import GRDB

/// SP-1.5 audit tool: detects duplicate audio files in the library.
/// Read-only — does not delete, move, or modify anything. The user
/// resolves duplicates manually via Finder (or via a future
/// "consolidate Serato references onto the keeper" action).
///
/// Two detection modes:
///
/// - **Byte-level**: clusters files sharing `file_size` and
///   `lightweight_hash` (SHA-256 of the first and last 1 MB), then confirms
///   each cluster with a digest of every byte (`OwnedAudioIdentity`). Two
///   untagged edits of equal length can share the partial hash, so files
///   whose full contents differ are kept.
///
/// - **Perceptual**: clusters files sharing a `chromaprint_fingerprint`
///   (first 120 s), then splits each cluster by decoded audio. Different
///   versions such as Clean and Dirty edits can share a 120 s fingerprint.
///
/// In both modes identical bytes or PCM are the only basis for
/// pre-selecting cleanup (`DuplicateEvidence.relation`). Perceptual files
/// whose PCM differs (another format or encoding) but which share a
/// full-length fingerprint and duration are grouped for listening and never
/// pre-selected. Unmatched or unreadable files are kept. A cluster with a
/// digest still pending is shown as checking and offers nothing. Only files
/// with a finished fingerprint are clustered perceptually.
public enum DuplicateFinder {
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case byteLevel
        case perceptual

        public var displayName: String {
            switch self {
            case .byteLevel: "Byte-level"
            case .perceptual: "Perceptual"
            }
        }
    }

    public enum Check: String, Sendable, Equatable {
        /// A member's digest is still being computed.
        case checking
        /// Every file in `files` has identical bytes (byte-level) or
        /// identical decoded PCM (perceptual).
        case confirmed
        /// Some files match only by full-length fingerprint and duration
        /// (another format or encoding), which is not proof: nothing is
        /// pre-selected and each file must be chosen explicitly.
        case needsListening
        /// No two files in the cluster match.
        case differs
    }

    public enum KeptReason: Sendable, Equatable {
        case differs
        case unreadable(String)
    }

    public struct KeptFile<File: DuplicateFileSource>: Sendable, Equatable {
        public let file: File
        public let reason: KeptReason
    }

    /// One cluster of files that match each other under the current
    /// detection mode. `files` is sorted by path for deterministic
    /// UI rendering. `keptFiles` share the cluster's candidate key but are
    /// never offered for cleanup.
    public struct DuplicateGroup<File: DuplicateFileSource>: Sendable, Equatable, Identifiable {
        public let groupKey: String
        public let mode: Mode
        public let files: [File]
        public let check: Check
        public let keptFiles: [KeptFile<File>]
        /// Digest evidence per file id.
        public let evidence: [Int64: DuplicateEvidence]

        /// A group is unconfirmed until its files' digests are checked.
        public init(groupKey: String, mode: Mode, files: [File], check: Check = .checking, keptFiles: [KeptFile<File>] = [],
                    evidence: [Int64: DuplicateEvidence] = [:])
        {
            self.groupKey = groupKey
            self.mode = mode
            self.files = files
            self.check = check
            self.keptFiles = keptFiles
            self.evidence = evidence
        }

        /// Whether any file here may be moved to Trash at all.
        public var offersCleanup: Bool {
            files.count > 1 && (check == .confirmed || check == .needsListening)
        }

        /// Whether every non-keeper is selected for Trash by default.
        public var preselectsCleanup: Bool {
            files.count > 1 && check == .confirmed
        }

        /// Files whose digest is still being computed.
        public var uncheckedFileCount: Int {
            files.count(where: { file in file.id.flatMap { identifier in evidence[identifier] }.map(\.isPending) ?? true })
        }

        /// How `file` relates to `keeper` by digest, or nil when the group
        /// has no evidence for either.
        public func relation(of file: File, toKeeper keeper: File) -> DuplicateEvidence.Relation? {
            guard let fileID = file.id, let keeperID = keeper.id, let fileEvidence = evidence[fileID], let keeperEvidence = evidence[keeperID]
            else { return nil }
            return DuplicateEvidence.relation(fileEvidence, keeperEvidence)
        }

        public var id: String {
            "\(mode.rawValue):\(groupKey)"
        }

        public var size: Int {
            files.count
        }
    }

    /// Find groups according to `mode`. SQLite does the grouping, so
    /// only rows that belong to a group of two or more are decoded,
    /// and the Chromaprint BLOB is read only for those rows. Files
    /// lacking the mode's key (no lightweight hash; no finished
    /// fingerprint) can't be matched and are excluded, as are files
    /// that aren't processable library members. Groups are ordered
    /// biggest first, then by key.
    public static func findDuplicates(in database: Database, mode: Mode) throws -> [DuplicateGroup<DuplicateFileRow>] {
        var membersByKey: [String: [DuplicateConfirmation.Member]] = [:]
        let rows = try Row.fetchCursor(database, sql: memberSQL(for: mode))
        while let row = try rows.next() {
            let file = try DuplicateFileRow(row: row)
            let evidence = try DuplicateDigestStore.evidence(from: row, kind: mode.digestKind)
            membersByKey[groupKey(mode: mode, fileSize: file.fileSize, keyBytes: row["group_blob"]), default: []]
                .append(.init(file: file, evidence: evidence))
        }
        return membersByKey
            .flatMap { key, members in DuplicateConfirmation.groups(clusterKey: key, mode: mode, members: members) }
            .sorted { lhs, rhs in
                if lhs.size != rhs.size {
                    return lhs.size > rhs.size
                }
                return lhs.groupKey < rhs.groupKey
            }
    }

    /// How many processable files have a finished fingerprint, for the
    /// UI's "X of Y fingerprinted" badge: a low perceptual count may
    /// mean fingerprinting is still in progress, not zero duplicates.
    public static func fingerprintCoverage(in database: Database) throws -> (done: Int, total: Int) {
        let row = try Row.fetchOne(database, sql: """
        SELECT COUNT(*) AS total,
               COALESCE(SUM(files.fingerprint_status = ? AND files.chromaprint_fingerprint IS NOT NULL), 0) AS done
        FROM files WHERE \(FileProcessingEligibility.processableSQL)
        """, arguments: [FingerprintStatus.done.rawValue])
        return (done: row?["done"] ?? 0, total: row?["total"] ?? 0)
    }

    /// Cluster members with no digest for their current size, mtime and
    /// inode: the files `DuplicateEvidenceVerifier` checks.
    static func filesAwaitingCheck(in database: Database, mode: Mode) throws -> [DigestCandidate] {
        try Row.fetchAll(database, sql: memberSQL(for: mode, digestFilter: "AND digest.file_id IS NULL")).map(candidate)
    }

    /// Cluster members with a cached digest, and its stored basis, for
    /// revalidation against the live file.
    static func filesWithCachedCheck(in database: Database, mode: Mode) throws -> [(candidate: DigestCandidate, row: Row)] {
        try Row.fetchAll(database, sql: memberSQL(for: mode, digestFilter: "AND digest.file_id IS NOT NULL")).map { row in (candidate(row), row) }
    }

    private static func candidate(_ row: Row) -> DigestCandidate {
        DigestCandidate(fileID: row["id"], path: row["path"], fileSize: row["file_size"], mtime: row["mtime"], inode: row["inode"])
    }

    private static func memberSQL(for mode: Mode, digestFilter: String = "") -> String {
        let keyColumns: String
        let keyBlobColumn: String
        let keyCondition: String
        switch mode {
        case .byteLevel:
            keyBlobColumn = "files.lightweight_hash"
            keyColumns = "files.file_size, \(keyBlobColumn)"
            keyCondition = "\(keyBlobColumn) IS NOT NULL"
        case .perceptual:
            keyBlobColumn = "files.chromaprint_fingerprint"
            keyColumns = keyBlobColumn
            keyCondition = "files.fingerprint_status = '\(FingerprintStatus.done.rawValue)' AND \(keyBlobColumn) IS NOT NULL"
        }
        let eligibleSQL = "\(FileProcessingEligibility.processableSQL) AND \(keyCondition)"
        return """
        SELECT \(DuplicateFileRow.columnsSQL), \(keyBlobColumn) AS group_blob, \(DuplicateDigestStore.columnsSQL(mode.digestKind))
        FROM files
        \(DuplicateDigestStore.freshJoinSQL(mode.digestKind))
        WHERE \(eligibleSQL) \(digestFilter)
          AND (\(keyColumns)) IN (
            SELECT \(keyColumns) FROM files WHERE \(eligibleSQL)
            GROUP BY \(keyColumns) HAVING COUNT(*) > 1
          )
        ORDER BY files.path
        """
    }

    /// Byte-level keys keep the size alongside the 32-byte hash, as a
    /// guard against a cross-size hash collision. Perceptual keys
    /// digest the multi-kilobyte fingerprint so group identifiers stay
    /// short and stable while fingerprints land.
    private static func groupKey(mode: Mode, fileSize: Int64, keyBytes: Data) -> String {
        switch mode {
        case .byteLevel:
            "\(fileSize):\(keyBytes.base64EncodedString())"
        case .perceptual:
            SHA256.hash(data: keyBytes).map { byte in String(format: "%02x", byte) }.joined()
        }
    }
}
