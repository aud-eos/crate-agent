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
/// - **Perceptual**: groups files that are the same *recording*,
///   even at different bitrates or in different formats. Match
///   condition: same `chromaprint_fingerprint`. Chromaprint by
///   design produces stable hashes across re-encodings of the same
///   audio. Result only meaningful for files where the
///   FingerprintWorker has produced a fingerprint
///   (`fingerprint_status = 'done'`); pending / failed rows are
///   excluded from perceptual grouping.
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

    /// One cluster of files that match each other under the current
    /// detection mode. `files` is sorted by path for deterministic
    /// UI rendering.
    public struct DuplicateGroup<File: DuplicateFileSource>: Sendable, Equatable, Identifiable {
        public let groupKey: String
        public let mode: Mode
        public let files: [File]

        public init(groupKey: String, mode: Mode, files: [File]) {
            self.groupKey = groupKey
            self.mode = mode
            self.files = files
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
        var membersByKey: [String: [DuplicateFileRow]] = [:]
        let rows = try Row.fetchCursor(database, sql: memberSQL(for: mode))
        while let row = try rows.next() {
            let member = try DuplicateFileRow(row: row)
            membersByKey[groupKey(mode: mode, fileSize: member.fileSize, keyBytes: row["group_blob"]), default: []].append(member)
        }
        return membersByKey
            .map { key, members in DuplicateGroup(groupKey: key, mode: mode, files: members) }
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

    private static func memberSQL(for mode: Mode) -> String {
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
        SELECT \(DuplicateFileRow.columnsSQL), \(keyBlobColumn) AS group_blob
        FROM files
        WHERE \(eligibleSQL)
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
