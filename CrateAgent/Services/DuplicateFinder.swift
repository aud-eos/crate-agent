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
/// - **Byte-level**: groups files that are byte-equivalent. Match
///   condition: same `file_size` AND same `lightweight_hash`. Picks
///   up the classic "copied the same MP3 into two folders" case.
///   The lightweight hash (SHA-256 of first 1MB + last 1MB) was
///   populated for cross-volume move detection in #13; it doubles
///   as the duplicate-detection primitive here at zero extra cost.
///
/// - **Perceptual**: clusters files sharing a `chromaprint_fingerprint`
///   (first 120 s), then splits each cluster by decoded audio
///   (`DuplicateAudioEvidence.relation`). Different versions such as Clean
///   and Dirty edits can share a 120 s fingerprint. Identical decoded PCM
///   is the only basis for pre-selecting cleanup; files whose PCM differs
///   (another format or encoding) but share a full-length fingerprint and
///   duration are grouped for listening, but are
///   never pre-selected. Unmatched or undecodable files are kept. A cluster
///   with a digest still pending is shown as checking and offers nothing.
///   Only files with a finished fingerprint are clustered.
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

    public enum AudioCheck: String, Sendable, Equatable {
        /// Byte-level groups match on content hashes, not decoded audio.
        case notRequired
        /// A member's decoded-audio digest is still being computed.
        case checking
        /// Every file in `files` decodes to identical PCM.
        case confirmed
        /// Some files match only by full-length fingerprint and duration
        /// (another format or encoding), which is not proof: nothing is
        /// pre-selected and each file must be chosen explicitly.
        case needsListening
        /// No two files in the fingerprint cluster share their audio.
        case differs
    }

    public enum KeptReason: Sendable, Equatable {
        case audioDiffers
        case unreadable(String)
    }

    public struct KeptFile<File: DuplicateFileSource>: Sendable, Equatable {
        public let file: File
        public let reason: KeptReason
    }

    /// One cluster of files that match each other under the current
    /// detection mode. `files` is sorted by path for deterministic
    /// UI rendering. `keptFiles` share the cluster's fingerprint but are
    /// never offered for cleanup.
    public struct DuplicateGroup<File: DuplicateFileSource>: Sendable, Equatable, Identifiable {
        public let groupKey: String
        public let mode: Mode
        public let files: [File]
        public let audioCheck: AudioCheck
        public let keptFiles: [KeptFile<File>]
        /// Decoded-audio evidence per file id, for perceptual groups.
        public let audio: [Int64: DuplicateAudioEvidence.DecodedAudio]

        /// A perceptual group is unconfirmed until its audio is checked.
        public init(groupKey: String, mode: Mode, files: [File], audioCheck: AudioCheck? = nil, keptFiles: [KeptFile<File>] = [],
                    audio: [Int64: DuplicateAudioEvidence.DecodedAudio] = [:])
        {
            self.groupKey = groupKey
            self.mode = mode
            self.files = files
            self.audioCheck = audioCheck ?? (mode == .byteLevel ? .notRequired : .checking)
            self.keptFiles = keptFiles
            self.audio = audio
        }

        /// Whether any file here may be moved to Trash at all.
        public var offersCleanup: Bool {
            files.count > 1 && [.notRequired, .confirmed, .needsListening].contains(audioCheck)
        }

        /// Whether every non-keeper is selected for Trash by default.
        public var preselectsCleanup: Bool {
            files.count > 1 && (audioCheck == .notRequired || audioCheck == .confirmed)
        }

        /// How `file` relates to `keeper` by decoded audio, or nil when the
        /// group has no audio evidence for either.
        public func audioRelation(of file: File, toKeeper keeper: File) -> DuplicateAudioEvidence.Relation? {
            guard let fileID = file.id, let keeperID = keeper.id, let fileAudio = audio[fileID], let keeperAudio = audio[keeperID]
            else { return nil }
            return DuplicateAudioEvidence.relation(fileAudio, keeperAudio)
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
        var membersByKey: [String: [DuplicateAudioConfirmation.Member]] = [:]
        let rows = try Row.fetchCursor(database, sql: memberSQL(for: mode))
        while let row = try rows.next() {
            let file = try DuplicateFileRow(row: row)
            let evidence = mode == .perceptual ? try AudioDigestStore.evidence(from: row) : .pending
            membersByKey[groupKey(mode: mode, fileSize: file.fileSize, keyBytes: row["group_blob"]), default: []]
                .append(.init(file: file, evidence: evidence))
        }
        return membersByKey
            .flatMap { key, members in
                switch mode {
                case .byteLevel: [DuplicateGroup(groupKey: key, mode: mode, files: members.map(\.file))]
                case .perceptual: DuplicateAudioConfirmation.groups(clusterKey: key, members: members)
                }
            }
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

    /// Perceptual-cluster members with no digest for their current size,
    /// mtime and inode: the files `DuplicateAudioVerifier` decodes.
    static func filesAwaitingAudioCheck(in database: Database) throws -> [(fileID: Int64, path: String, basis: AudioDigestBasis)] {
        try Row.fetchAll(database, sql: memberSQL(for: .perceptual, pendingAudioOnly: true)).map { row in
            (fileID: row["id"], path: row["path"], basis: AudioDigestBasis(fileSize: row["file_size"], mtime: row["mtime"], inode: row["inode"]))
        }
    }

    private static func memberSQL(for mode: Mode, pendingAudioOnly: Bool = false) -> String {
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
        let audioColumns = mode == .perceptual ? ", \(AudioDigestStore.columnsSQL)" : ""
        let audioJoin = mode == .perceptual ? AudioDigestStore.freshJoinSQL : ""
        let pendingAudio = pendingAudioOnly ? "AND audio.file_id IS NULL" : ""
        return """
        SELECT \(DuplicateFileRow.columnsSQL), \(keyBlobColumn) AS group_blob\(audioColumns)
        FROM files
        \(audioJoin)
        WHERE \(eligibleSQL) \(pendingAudio)
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
