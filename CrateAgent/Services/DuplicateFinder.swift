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
    public enum Mode: String, Codable, Sendable, Equatable, CaseIterable {
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

    /// A confirmed group whose copies name different version labels
    /// (`DuplicateLabelReview`). `keptBoth` records that the user chose to
    /// keep every copy; it lasts while `signature` still matches.
    public struct LabelReview: Sendable, Equatable {
        public let signature: String
        public let keptBoth: Bool
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
        /// Set when the copies' version labels disagree.
        public let labelReview: LabelReview?

        /// A group is unconfirmed until its files' digests are checked.
        public init(groupKey: String, mode: Mode, files: [File], check: Check = .checking, keptFiles: [KeptFile<File>] = [],
                    evidence: [Int64: DuplicateEvidence] = [:], labelReview: LabelReview? = nil)
        {
            self.groupKey = groupKey
            self.mode = mode
            self.files = files
            self.check = check
            self.keptFiles = keptFiles
            self.evidence = evidence
            self.labelReview = labelReview
        }

        /// Whether any file here may be moved to Trash at all. Copies the
        /// user chose to keep are not offered again.
        public var offersCleanup: Bool {
            files.count > 1 && (check == .confirmed || check == .needsListening) && labelReview?.keptBoth != true
        }

        /// Whether every non-keeper is selected for Trash by default, and a
        /// keeper chosen for the user. Never when labels disagree.
        public var preselectsCleanup: Bool {
            files.count > 1 && check == .confirmed && labelReview == nil
        }

        /// Whether the copies' labels disagree and the user hasn't kept them all.
        public var labelsDisagree: Bool {
            labelReview?.keptBoth == false
        }

        func withLabelReview(keptSignatures: Set<String>) -> Self {
            guard check == .confirmed, files.count > 1, DuplicateLabelReview.labelsDisagree(files),
                  let signature = DuplicateLabelReview.signature(of: self)
            else { return self }
            return Self(groupKey: groupKey, mode: mode, files: files, check: check, keptFiles: keptFiles, evidence: evidence,
                        labelReview: LabelReview(signature: signature, keptBoth: keptSignatures.contains(signature)))
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
        var membersByCluster: [Cluster: [DuplicateConfirmation.Member]] = [:]
        let playCounts = try SeratoPlayCounts.all(in: database)
        let rows = try Row.fetchCursor(database, sql: memberSQL(for: mode))
        while let row = try rows.next() {
            let file = try DuplicateFileRow(row: row, playCounts: playCounts)
            let evidence = try DuplicateDigestStore.evidence(from: row, kind: mode.digestKind)
            membersByCluster[Cluster(mode: mode, fileSize: file.fileSize, keyBytes: row["group_blob"]), default: []]
                .append(.init(file: file, evidence: evidence))
        }
        let keptSignatures = try DuplicateLabelReview.keptSignatures(in: database)
        return membersByCluster
            .flatMap { cluster, members in DuplicateConfirmation.groups(clusterKey: cluster.groupKey, mode: mode, members: members) }
            .map { group in group.withLabelReview(keptSignatures: keptSignatures) }
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
        let processable = FileProcessingEligibility.processableSQL
        let row = try Row.fetchOne(database, sql: """
        SELECT (SELECT COUNT(*) FROM files WHERE \(processable)) AS total,
               (SELECT COUNT(*) FROM files WHERE \(processable) AND \(fingerprintedSQL)) AS done
        """)
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

    private static let fingerprintColumn = "files.chromaprint_fingerprint"
    private static let fingerprintedSQL = "files.fingerprint_status = '\(FingerprintStatus.done.rawValue)' AND \(fingerprintColumn) IS NOT NULL"

    private static func memberSQL(for mode: Mode, digestFilter: String = "") -> String {
        """
        SELECT \(DuplicateFileRow.columnsSQL), \(keyBlobColumn(mode)) AS group_blob, \(DuplicateDigestStore.columnsSQL(mode.digestKind))
        FROM files
        \(DuplicateDigestStore.freshJoinSQL(mode.digestKind))
        WHERE \(clusterMemberSQL(mode)) \(digestFilter)
        ORDER BY files.path
        """
    }

    private static func keyBlobColumn(_ mode: Mode) -> String {
        switch mode {
        case .byteLevel: "files.lightweight_hash"
        case .perceptual: fingerprintColumn
        }
    }

    /// Selects processable files whose candidate key another processable
    /// file shares.
    static func clusterMemberSQL(_ mode: Mode) -> String {
        let keyBlob = keyBlobColumn(mode)
        let eligibleSQL: String
        let clusteredIDsSQL: String
        switch mode {
        case .byteLevel:
            eligibleSQL = "\(FileProcessingEligibility.processableSQL) AND \(keyBlob) IS NOT NULL"
            clusteredIDsSQL = idsSharingSQL(key: "files.file_size, \(keyBlob)", among: eligibleSQL)
        case .perceptual:
            eligibleSQL = "\(FileProcessingEligibility.processableSQL) AND \(fingerprintedSQL)"
            // Partitioning every multi-kilobyte fingerprint is the scan's
            // largest cost, so only files that share a fingerprint's length
            // and final frames are compared by the whole fingerprint.
            let candidateIDsSQL = idsSharingSQL(key: "length(\(keyBlob)), substr(\(keyBlob), -32)", among: eligibleSQL)
            clusteredIDsSQL = idsSharingSQL(key: keyBlob, among: "files.id IN (\(candidateIDsSQL))")
        }
        return "\(eligibleSQL) AND files.id IN (\(clusteredIDsSQL))"
    }

    /// Ids of the `filter` rows whose `key` at least one other such row shares.
    private static func idsSharingSQL(key: String, among filter: String) -> String {
        "SELECT id FROM (SELECT files.id, COUNT(*) OVER (PARTITION BY \(key)) AS copies FROM files WHERE \(filter)) WHERE copies > 1"
    }

    /// What a cluster's files share. Byte-level clusters keep the size
    /// alongside the 32-byte hash, as a guard against a cross-size hash
    /// collision.
    private struct Cluster: Hashable {
        let fileSize: Int64?
        let keyBytes: Data

        init(mode: Mode, fileSize: Int64, keyBytes: Data) {
            self.fileSize = mode == .byteLevel ? fileSize : nil
            self.keyBytes = keyBytes
        }

        /// Perceptual keys digest the multi-kilobyte fingerprint so group
        /// identifiers stay short and stable while fingerprints land.
        var groupKey: String {
            if let fileSize {
                "\(fileSize):\(keyBytes.base64EncodedString())"
            } else {
                SHA256.hash(data: keyBytes).lowercaseHex
            }
        }
    }
}
