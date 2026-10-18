import Foundation
import GRDB

/// Whole-library outcome of fingerprinting, independent of any one worker run.
/// `done` counts only usable fingerprints; a `done` label without a decodable
/// fingerprint is `invalid`, never coverage.
struct FingerprintCoverage: Equatable, Sendable {
    var eligible = 0
    var done = 0
    var pending = 0
    var failed = 0
    var invalid = 0
    /// Indexed rows whose audio is missing, trashed, offline, inaccessible or unknown.
    var unavailable = 0
    /// Available rows whose Serato membership is not confirmed yet (legacy or pending import).
    var awaitingMembership = 0
    var removedFromSerato = 0
}

/// Whole-library outcome of file-info scanning: where each indexed file was last observed.
struct FileInfoCoverage: Equatable, Sendable {
    var indexed = 0
    var available = 0
    var missing = 0
    var trashed = 0
    var offline = 0
    var inaccessible = 0
    var unknown = 0
    var removedFromSerato = 0
}

struct WorkerCoverage: Equatable, Sendable {
    var fingerprint = FingerprintCoverage()
    var fileInfo = FileInfoCoverage()
}

enum WorkerFileCategory: String, CaseIterable, Identifiable, Sendable {
    case failed, invalid, pending, unavailable

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .failed: "Failed"
        case .invalid: "Invalid results"
        case .pending: "Pending"
        case .unavailable: "Unavailable"
        }
    }

    var isRetryable: Bool {
        self == .failed || self == .invalid
    }

    fileprivate var predicate: String {
        switch self {
        case .failed: "\(FileProcessingEligibility.processableSQL) AND fingerprint_status = 'failed'"
        case .invalid: "\(FileProcessingEligibility.processableSQL) AND (\(WorkerCoverageQuery.invalidDoneSQL))"
        case .pending: "\(FileProcessingEligibility.processableSQL) AND fingerprint_status = 'pending'"
        case .unavailable: "\(FileProcessingEligibility.activeSQL) AND file_availability != 'available'"
        }
    }
}

struct WorkerFileRow: Equatable, Identifiable, Sendable {
    let id: Int64
    let path: String
    let availability: FileAvailability
    let detail: String?
}

enum WorkerCoverageQuery {
    /// A `done` label whose stored bytes cannot be a Chromaprint fingerprint (see `FingerprintEncoder`).
    static let invalidDoneSQL = """
    fingerprint_status = 'done' AND (chromaprint_fingerprint IS NULL OR length(chromaprint_fingerprint) = 0 \
    OR length(chromaprint_fingerprint) % 4 != 0)
    """

    static let drillDownLimit = 200

    /// One aggregate pass over `files`; no rows or fingerprint blobs are decoded.
    static func fetch(in database: Database) throws -> WorkerCoverage {
        let processable = FileProcessingEligibility.processableSQL
        let active = FileProcessingEligibility.activeSQL
        let sql = """
        SELECT
          COALESCE(SUM(\(processable)), 0) AS eligible,
          COALESCE(SUM(\(processable) AND fingerprint_status = 'done' AND NOT (\(invalidDoneSQL))), 0) AS done,
          COALESCE(SUM(\(processable) AND fingerprint_status = 'pending'), 0) AS pending,
          COALESCE(SUM(\(processable) AND fingerprint_status = 'failed'), 0) AS failed,
          COALESCE(SUM(\(processable) AND (\(invalidDoneSQL))), 0) AS invalid,
          COALESCE(SUM(\(active)), 0) AS indexed,
          COALESCE(SUM(\(active) AND file_availability = 'available'), 0) AS available,
          COALESCE(SUM(\(active) AND file_availability = 'missing'), 0) AS missing,
          COALESCE(SUM(\(active) AND file_availability = 'trashed'), 0) AS trashed,
          COALESCE(SUM(\(active) AND file_availability = 'offline'), 0) AS offline,
          COALESCE(SUM(\(active) AND file_availability = 'inaccessible'), 0) AS inaccessible,
          COALESCE(SUM(\(active) AND file_availability = 'unknown'), 0) AS unknown,
          COALESCE(SUM(NOT (\(active))), 0) AS removed
        FROM files
        """
        guard let row = try Row.fetchOne(database, sql: sql) else { return WorkerCoverage() }
        let removed: Int = row["removed"]
        let available: Int = row["available"]
        let indexed: Int = row["indexed"]
        return WorkerCoverage(
            fingerprint: FingerprintCoverage(eligible: row["eligible"], done: row["done"], pending: row["pending"], failed: row["failed"],
                                             invalid: row["invalid"], unavailable: indexed - available,
                                             awaitingMembership: available - row["eligible"], removedFromSerato: removed),
            fileInfo: FileInfoCoverage(indexed: indexed, available: available, missing: row["missing"], trashed: row["trashed"],
                                       offline: row["offline"], inaccessible: row["inaccessible"], unknown: row["unknown"],
                                       removedFromSerato: removed)
        )
    }

    static func files(in category: WorkerFileCategory, database: Database) throws -> [WorkerFileRow] {
        let rows = try Row.fetchAll(database, sql: """
        SELECT id, path, file_availability, fingerprint_failure FROM files
        WHERE \(category.predicate) ORDER BY path LIMIT \(drillDownLimit)
        """)
        return try rows.map { row in
            let availabilityValue: String = row["file_availability"]
            guard let availability = FileAvailability(rawValue: availabilityValue) else {
                throw WorkerCoverageError.unknownAvailability(availabilityValue)
            }
            return WorkerFileRow(id: row["id"], path: row["path"], availability: availability,
                                 detail: detail(for: category, availability: availability, failure: row["fingerprint_failure"]))
        }
    }

    private static func detail(for category: WorkerFileCategory, availability: FileAvailability, failure: String?) -> String? {
        switch category {
        case .failed: failure ?? "No failure reason was recorded for this attempt."
        case .invalid: "Marked done without a usable fingerprint."
        case .pending: nil
        case .unavailable: "File is \(availability.rawValue); it is not fingerprinted until it is available."
        }
    }

    static func failureReason(for error: Error) -> String {
        guard let coreError = error as? CoreError else { return error.localizedDescription }
        return coreError.message ?? "Fingerprinting is not implemented for this file."
    }
}

enum WorkerCoverageError: LocalizedError {
    case unknownAvailability(String)

    var errorDescription: String? {
        switch self {
        case let .unknownAvailability(value): "The library contains an unknown file availability \"\(value)\"."
        }
    }
}
