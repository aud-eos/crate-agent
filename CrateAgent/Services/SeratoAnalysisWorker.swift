import Foundation
import GRDB
import os.log

extension SeratoAnalysis: @unchecked Sendable {}

/// Why a file's Serato cues and beatgrid couldn't be read. An unsupported
/// format can't carry Serato data crate-agent reads, so its cues are unknown,
/// not missing; a malformed payload or container is a fault in the file; an
/// I/O failure may clear, so it is read again on a later pass.
struct SeratoAnalysisFailure: Error, Equatable, Sendable {
    /// The raw value is the token that begins the stored failure text.
    enum Kind: String, CaseIterable, Sendable {
        case unsupportedFormat = "unsupported"
        case malformed
        case container
        case io

        var isRetryable: Bool {
            self == .io
        }

        var detailPrefix: String {
            switch self {
            case .unsupportedFormat: SeratoAnalysisMessages.unsupportedDetailPrefix
            case .malformed: SeratoAnalysisMessages.malformedDetailPrefix
            case .container: SeratoAnalysisMessages.containerDetailPrefix
            case .io: SeratoAnalysisMessages.ioDetailPrefix
            }
        }

        var storedPrefix: String {
            "\(rawValue): "
        }
    }

    let kind: Kind
    let reason: String

    /// An error other than the reader's own is an I/O failure: it says
    /// nothing about the file's bytes.
    init(_ error: Error) {
        switch error as? SeratoAnalysisError {
        case let .UnsupportedFormat(format): self.init(kind: .unsupportedFormat, reason: format)
        case let .Malformed(field, reason): self.init(kind: .malformed, reason: SeratoAnalysisMessages.malformedReason(field: field, reason: reason))
        case let .Container(message): self.init(kind: .container, reason: message)
        case let .Io(message): self.init(kind: .io, reason: message)
        case nil: self.init(kind: .io, reason: UserFacingErrorMessage.message(for: error))
        }
    }

    init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    init(stored: String) throws {
        guard let kind = Kind.allCases.first(where: { kind in stored.hasPrefix(kind.storedPrefix) }) else {
            throw SeratoAnalysisStoreError.unknownFailure(stored)
        }
        self.init(kind: kind, reason: String(stored.dropFirst(kind.storedPrefix.count)))
    }

    /// What `file_serato_analysis.failure` holds.
    var stored: String {
        kind.storedPrefix + reason
    }

    var detail: String {
        SeratoAnalysisMessages.detail(prefix: kind.detailPrefix, reason: reason)
    }
}

enum SeratoAnalysisStoreError: LocalizedError {
    case unknownFailure(String)

    var errorDescription: String? {
        switch self {
        case let .unknownFailure(stored): SeratoAnalysisMessages.unknownFailure(stored)
        }
    }
}

struct SeratoAnalysisResult: Sendable {
    let fileID: Int64
    let basis: DigestBasis
    let outcome: Result<SeratoAnalysis, SeratoAnalysisFailure>
}

enum SeratoAnalysisStore {
    static let table = "file_serato_analysis"

    static func freshJoinSQL(as alias: String = "analysis") -> String {
        DerivedFileCache.freshJoinSQL(table: table, alias: alias)
    }

    /// Processable files with no row for their indexed basis, or whose row
    /// is a retryable failure, in id order after `fileID`.
    static func pending(after fileID: Int64 = 0, limit: Int, in database: GRDB.Database) throws -> [DigestCandidate] {
        try Row.fetchAll(database, sql: """
        SELECT files.id, files.path, files.file_size, files.mtime, files.inode FROM files
        \(freshJoinSQL())
        WHERE \(FileProcessingEligibility.processableSQL) AND (analysis.file_id IS NULL OR analysis.retryable) AND files.id > ?
        ORDER BY files.id LIMIT ?
        """, arguments: [fileID, limit]).map { row in
            DigestCandidate(fileID: row["id"], path: row["path"], fileSize: row["file_size"], mtime: row["mtime"], inode: row["inode"])
        }
    }

    static func save(_ results: [SeratoAnalysisResult], in database: GRDB.Database) throws {
        for result in results {
            let values: [(any DatabaseValueConvertible)?] = switch result.outcome {
            case let .success(analysis): [Int(analysis.cueCount), Int(analysis.beatgridMarkerCount), nil, false]
            case let .failure(failure): [nil, nil, failure.stored, failure.kind.isRetryable]
            }
            try DerivedFileCache.save(columns: "cue_count, beatgrid_marker_count, failure, retryable", values: values, table: table,
                                      fileID: result.fileID, basis: result.basis, in: database)
        }
    }

    /// One aggregate pass over processable files.
    static func coverage(in database: GRDB.Database) throws -> SeratoAnalysisCoverage {
        guard let row = try Row.fetchOne(database, sql: """
        SELECT
          COALESCE(SUM(analysis.file_id IS NOT NULL AND analysis.failure IS NULL), 0) AS read,
          COALESCE(SUM(analysis.file_id IS NULL), 0) AS pending,
          COALESCE(SUM(analysis.failure IS NOT NULL), 0) AS failures,
          COALESCE(SUM(\(isUnsupportedSQL)), 0) AS unsupported,
          COALESCE(SUM(analysis.retryable), 0) AS retryable
        FROM files \(freshJoinSQL())
        WHERE \(FileProcessingEligibility.processableSQL)
        """, arguments: [SeratoAnalysisFailure.Kind.unsupportedFormat.storedPrefix]) else {
            return SeratoAnalysisCoverage(read: 0, pending: 0, failed: 0)
        }
        let failures: Int = row["failures"]
        let unsupported: Int = row["unsupported"]
        return SeratoAnalysisCoverage(read: row["read"], pending: row["pending"], failed: failures - unsupported, unsupported: unsupported,
                                      retryable: row["retryable"])
    }

    /// Takes the unsupported-format prefix as its argument.
    private static let isUnsupportedSQL = "instr(analysis.failure, ?) = 1"

    /// Processable files whose cues couldn't be read, with the failure's
    /// kind and reason in `detail`: faults first, then unsupported formats,
    /// each by path, so many unsupported files can't hide a malformed one.
    static func failures(limit: Int, in database: GRDB.Database) throws -> [WorkerFileRow] {
        try Row.fetchAll(database, sql: """
        SELECT files.id, files.path, files.file_availability, analysis.failure FROM files
        \(freshJoinSQL())
        WHERE \(FileProcessingEligibility.processableSQL) AND analysis.failure IS NOT NULL
        ORDER BY \(isUnsupportedSQL), files.path LIMIT ?
        """, arguments: [SeratoAnalysisFailure.Kind.unsupportedFormat.storedPrefix, limit]).map { row in
            let availabilityValue: String = row["file_availability"]
            guard let availability = FileAvailability(rawValue: availabilityValue) else {
                throw WorkerCoverageError.unknownAvailability(availabilityValue)
            }
            return try WorkerFileRow(id: row["id"], path: row["path"], availability: availability,
                                     detail: SeratoAnalysisFailure(stored: row["failure"]).detail)
        }
    }
}

/// Reads every processable file's Serato cue points and beatgrid markers
/// from its tags, once per file basis, in the background. Reads only the
/// audio file and never writes it or its `files` row, so a read can't look
/// like a replacement or touch recording identity.
public actor SeratoAnalysisWorker {
    typealias AnalysisReader = @Sendable (String) throws -> SeratoAnalysis

    /// What the worker last reported: the library's coverage after a pass,
    /// or why it stopped.
    struct Status: Equatable, Sendable {
        let coverage: SeratoAnalysisCoverage?
        let error: String?
    }

    typealias StatusHandler = @Sendable (Status) -> Void

    static let batchSize = 200
    /// How long a retryable failure waits for its next read when nothing
    /// else wakes the worker.
    static let retryInterval: Duration = .seconds(60)
    private static let pollInterval: Duration = .seconds(5)
    private static let logger = Logger(subsystem: "com.crateagent.app", category: "SeratoAnalysisWorker")

    private let database: LibraryDatabase
    private let readiness: LibrarySyncReadiness
    private let readAnalysis: AnalysisReader
    private var workTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var runID: UUID?
    private var filesObservation: AnyDatabaseCancellable?
    private var statusHandler: StatusHandler?
    private(set) var status: Status?

    init(database: LibraryDatabase, readiness: LibrarySyncReadiness,
         readAnalysis: @escaping @Sendable (String) throws -> SeratoAnalysis = { path in try readSeratoAnalysis(filePath: path) })
    {
        self.database = database
        self.readiness = readiness
        self.readAnalysis = readAnalysis
    }

    /// Runs a pass now and again whenever an indexed file's basis or
    /// eligibility changes: a cue edited in Serato changes the file's stat,
    /// which the next sync records, leaving its row stale. While a
    /// retryable failure remains, a pass also runs `retryInterval` later.
    func start(status handler: StatusHandler? = nil) {
        guard workTask == nil || workTask?.isCancelled == true else { return }
        let runID = UUID()
        self.runID = runID
        statusHandler = handler
        status = nil
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let tracked = SQLRequest<Row>(sql: "SELECT file_size, mtime, inode, library_membership, file_availability FROM files")
        filesObservation = DatabaseRegionObservation(tracking: tracked).start(in: database.writer, onError: { [weak self] error in
            continuation.finish()
            Task { await self?.fail(error, runID: runID) }
        }, onChange: { _ in continuation.yield() })
        workTask = Task.detached(priority: .utility) { await self.run(changes: changes, wake: continuation, runID: runID) }
    }

    func stop() {
        workTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        filesObservation?.cancel()
        filesObservation = nil
    }

    func waitUntilStopped() async {
        await workTask?.value
    }

    /// Reads every pending file once, a batch at a time, and returns the
    /// library's coverage. A file whose stat changes during its read is
    /// skipped; the sync that records the change makes it pending again.
    /// The cursor visits each file at most once, so a retryable failure is
    /// read again only by a later pass.
    @discardableResult
    func processAllPendingOnce() async throws -> SeratoAnalysisCoverage {
        let authorization = try readiness.capture()
        let readAnalysis = readAnalysis
        var cursor: Int64 = 0
        while true {
            try Task.checkCancellation()
            let after = cursor
            let batch = try await database.writer.read { connection in
                try SeratoAnalysisStore.pending(after: after, limit: Self.batchSize, in: connection)
            }
            guard let last = batch.last else { break }
            cursor = last.fileID
            let results = await Task.detached(priority: .utility) {
                batch.compactMap { candidate in Self.analyse(candidate, readAnalysis: readAnalysis) }
            }.value
            try authorization.check()
            try await database.writer.write { connection in try SeratoAnalysisStore.save(results, in: connection) }
        }
        return try await database.writer.read { connection in try SeratoAnalysisStore.coverage(in: connection) }
    }

    private func run(changes: AsyncStream<Void>, wake: AsyncStream<Void>.Continuation, runID: UUID) async {
        defer {
            if self.runID == runID {
                workTask = nil
                self.runID = nil
            }
        }
        var iterator = changes.makeAsyncIterator()
        while !Task.isCancelled {
            do {
                let coverage = try await processAllPendingOnce()
                report(Status(coverage: coverage, error: nil))
                scheduleRetry(coverage.retryable > 0 ? wake : nil)
            } catch is LibrarySyncReadinessError {
                try? await Task.sleep(for: Self.pollInterval)
                continue
            } catch is CancellationError {
                return
            } catch {
                fail(error, runID: runID)
                return
            }
            guard await iterator.next() != nil else { return }
        }
    }

    private func scheduleRetry(_ wake: AsyncStream<Void>.Continuation?) {
        retryTask?.cancel()
        retryTask = wake.map { wake in
            Task {
                try? await Task.sleep(for: Self.retryInterval)
                guard !Task.isCancelled else { return }
                wake.yield()
            }
        }
    }

    private func report(_ status: Status) {
        self.status = status
        statusHandler?(status)
    }

    private func fail(_ error: Error, runID: UUID) {
        guard self.runID == runID, !Task.isCancelled else { return }
        let message = SeratoAnalysisMessages.stopped(UserFacingErrorMessage.message(for: error))
        Self.logger.error("\(message, privacy: .public)")
        report(Status(coverage: nil, error: message))
        stop()
    }

    /// Nil when the live file doesn't match its indexed basis, or changes
    /// during the read: the result would describe other bytes.
    private static func analyse(_ candidate: DigestCandidate, readAnalysis: AnalysisReader) -> SeratoAnalysisResult? {
        guard let before = try? AudioFileReadIdentity.read(at: candidate.path) else { return nil }
        let live = before.target
        guard live.size == candidate.fileSize, Int64(live.modifiedSeconds) == candidate.mtime,
              Int64(bitPattern: live.inode) == candidate.inode
        else { return nil }
        let outcome: Result<SeratoAnalysis, SeratoAnalysisFailure>
        do {
            outcome = try .success(readAnalysis(candidate.path))
        } catch {
            outcome = .failure(SeratoAnalysisFailure(error))
        }
        guard (try? before.requireUnchanged(at: candidate.path)) != nil else { return nil }
        return SeratoAnalysisResult(fileID: candidate.fileID, basis: DigestBasis(indexed: candidate, live: live), outcome: outcome)
    }
}
