import CryptoKit
import Foundation
import GRDB

/// Same-audio duplicates whose titles name different version labels: one
/// copy says "(Clean)" and another "(Dirty)", or one says "(Instrumental)"
/// and another nothing. At least one label is wrong, so such a group is
/// never pre-selected and its keeper is never chosen for the user. The user
/// picks the keeper, may give it another copy's title, or keeps every copy.
public enum DuplicateLabelReview {
    static let table = "duplicate_label_reviews"

    /// Whether `files` name different sets of version labels.
    public static func labelsDisagree(_ files: [some DuplicateFileSource]) -> Bool {
        Set(files.map { file in VersionLabel.labels(in: file.title ?? "") }).count > 1
    }

    /// Identifies a confirmed group by its members and their digests, or nil
    /// when any member lacks a confirming digest.
    static func signature(mode: DuplicateFinder.Mode, members: [(fileID: Int64, evidence: DuplicateEvidence)]) -> String? {
        var canonical = mode.rawValue
        for member in members.sorted(by: { lhs, rhs in lhs.fileID < rhs.fileID }) {
            guard let digest = confirmingDigest(member.evidence) else { return nil }
            canonical += "|\(member.fileID):\(digest.base64EncodedString())"
        }
        return SHA256.hash(data: Data(canonical.utf8)).map { byte in String(format: "%02x", byte) }.joined()
    }

    static func signature(of group: DuplicateFinder.DuplicateGroup<some DuplicateFileSource>) -> String? {
        let members = group.files.compactMap { file in file.id.flatMap { identifier in group.evidence[identifier].map { (identifier, $0) } } }
        guard members.count == group.files.count else { return nil }
        return signature(mode: group.mode, members: members)
    }

    static func keptSignatures(in database: Database) throws -> Set<String> {
        try Set(String.fetchAll(database, sql: "SELECT signature FROM \(table)"))
    }

    /// Checks, inside the writer transaction, that the reviewed files are
    /// still processable, still identical by their fresh digests and still
    /// disagree, so a stale review can't be recorded.
    static func requireCurrent(_ payload: DuplicateLabelReviewPayload, in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: """
        SELECT \(DuplicateFileRow.columnsSQL), \(DuplicateDigestStore.columnsSQL(payload.mode.digestKind))
        FROM files
        \(DuplicateDigestStore.freshJoinSQL(payload.mode.digestKind))
        WHERE files.id IN (\(databaseQuestionMarks(count: payload.fileIds.count))) AND \(FileProcessingEligibility.processableSQL)
        """, arguments: StatementArguments(payload.fileIds))
        let files = try rows.map(DuplicateFileRow.init(row:))
        let members = try zip(files, rows).map { file, row in
            guard let fileID = file.id else { throw DuplicateLabelReviewError.superseded }
            return try (fileID: fileID, evidence: DuplicateDigestStore.evidence(from: row, kind: payload.mode.digestKind))
        }
        guard Set(payload.fileIds).count == payload.fileIds.count, files.count == payload.fileIds.count, files.count > 1,
              let first = members.first?.evidence,
              members.allSatisfy({ member in DuplicateEvidence.relation(member.evidence, first) == .identical }),
              labelsDisagree(files), signature(mode: payload.mode, members: members) == payload.signature
        else { throw DuplicateLabelReviewError.superseded }
    }

    private static func confirmingDigest(_ evidence: DuplicateEvidence) -> Data? {
        switch evidence {
        case let .content(digest): digest
        case let .decoded(audio): audio.pcmDigest
        case .pending, .unreadable: nil
        }
    }
}

/// A reviewed group of disagreeing same-audio copies.
public struct DuplicateLabelReviewPayload: Codable, Sendable, Equatable {
    public let signature: String
    public let mode: DuplicateFinder.Mode
    public let fileIds: [Int64]

    public init(signature: String, mode: DuplicateFinder.Mode, fileIds: [Int64]) {
        self.signature = signature
        self.mode = mode
        self.fileIds = fileIds
    }
}

public enum DuplicateLabelReviewOperation: Sendable {
    /// Keep every copy, and stop showing the disagreement until a copy changes.
    case keepBoth(DuplicateLabelReviewPayload)
    /// Show the disagreement again: the inverse of `keepBoth`.
    case reopen(DuplicateLabelReviewPayload)
}

public enum DuplicateLabelReviewError: LocalizedError, Equatable {
    case superseded
    case alreadyKept
    case notKept
    case titleNotInGroup

    public var errorDescription: String? {
        switch self {
        case .superseded: "These copies changed since they were reviewed. Rescan duplicates and review them again."
        case .alreadyKept: "These copies are already kept."
        case .notKept: "These copies are no longer marked as kept."
        case .titleNotInGroup: "That title doesn't belong to a copy in this group."
        }
    }
}

enum DuplicateLabelReviewMutation {
    static func apply(_ operation: DuplicateLabelReviewOperation, batchId: String, timestamp: Int64, in database: Database) throws -> Int64 {
        switch operation {
        case let .keepBoth(payload):
            try DuplicateLabelReview.requireCurrent(payload, in: database)
            guard try !exists(payload.signature, in: database) else { throw DuplicateLabelReviewError.alreadyKept }
            try database.execute(sql: "INSERT INTO \(DuplicateLabelReview.table) (signature, kept_at) VALUES (?, ?)", arguments: [payload.signature, timestamp])
            return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: nil, eventType: .duplicateLabelsKeptBoth,
                                                   forwardPayload: payload, inversePayload: payload, in: database)
        case let .reopen(payload):
            guard try exists(payload.signature, in: database) else { throw DuplicateLabelReviewError.notKept }
            try database.execute(sql: "DELETE FROM \(DuplicateLabelReview.table) WHERE signature = ?", arguments: [payload.signature])
            return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: nil, eventType: .duplicateLabelsReopened,
                                                   forwardPayload: payload, inversePayload: payload, in: database)
        }
    }

    private static func exists(_ signature: String, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM \(DuplicateLabelReview.table) WHERE signature = ?)", arguments: [signature]) ?? false
    }
}
