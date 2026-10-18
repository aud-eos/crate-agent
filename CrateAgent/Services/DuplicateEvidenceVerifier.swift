import Foundation
import GRDB

/// Computes duplicate-confirming digests lazily, only for members of
/// candidate clusters in the mode being viewed, with bounded concurrency off
/// the main actor: a digest of every byte for byte-level clusters, the
/// decoded-audio digest for perceptual ones. Each result is cached against
/// the file basis it was computed from.
public actor DuplicateEvidenceVerifier {
    public typealias AudioDigestFunction = @Sendable (String) throws -> DecodedAudioDigest
    public typealias ContentDigestFunction = @Sendable (String) throws -> Data

    private struct Pass {
        let generation: Int
        let task: Task<Void, Error>
    }

    private let database: LibraryDatabase
    private let concurrency: Int
    private let audioDigest: AudioDigestFunction
    private let contentDigest: ContentDigestFunction
    private var passes: [DuplicateFinder.Mode: Pass] = [:]
    private var waiters: [DuplicateFinder.Mode: Set<UUID>] = [:]
    private var generation = 0
    private static let saveBatchSize = 32

    init(
        database: LibraryDatabase,
        concurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount / 4),
        audioDigest: @escaping AudioDigestFunction = { path in try decodedAudioDigest(filePath: path) },
        contentDigest: @escaping ContentDigestFunction = { path in try OwnedAudioIdentity.read(at: path).digest }
    ) {
        self.database = database
        self.concurrency = max(1, concurrency)
        self.audioDigest = audioDigest
        self.contentDigest = contentDigest
    }

    /// Revalidates cached digests against the live files, retries transient
    /// failures, then checks every cluster member without a current digest,
    /// repeating until none remain. A call made while a pass for `mode` runs
    /// joins it. The pass is cancelled only when every caller waiting on it
    /// has been cancelled, and results already computed are saved first.
    public func verifyPendingFiles(mode: DuplicateFinder.Mode) async throws {
        let pass = currentPass(for: mode)
        let token = UUID()
        waiters[mode, default: []].insert(token)
        defer { release(token, mode: mode, generation: pass.generation) }
        try await withTaskCancellationHandler {
            try await pass.task.value
        } onCancel: {
            Task { await self.release(token, mode: mode, generation: pass.generation) }
        }
    }

    private func currentPass(for mode: DuplicateFinder.Mode) -> Pass {
        if let pass = passes[mode], !pass.task.isCancelled {
            return pass
        }
        generation += 1
        let passGeneration = generation
        let task = Task {
            defer { self.finished(mode: mode, generation: passGeneration) }
            try await self.run(mode: mode)
        }
        let pass = Pass(generation: passGeneration, task: task)
        passes[mode] = pass
        return pass
    }

    private func finished(mode: DuplicateFinder.Mode, generation: Int) {
        if passes[mode]?.generation == generation {
            passes[mode] = nil
        }
    }

    private func release(_ token: UUID, mode: DuplicateFinder.Mode, generation: Int) {
        waiters[mode]?.remove(token)
        guard let pass = passes[mode], pass.generation == generation, waiters[mode]?.isEmpty ?? true else { return }
        pass.task.cancel()
        passes[mode] = nil
    }

    private func run(mode: DuplicateFinder.Mode) async throws {
        try await revalidate(mode: mode)
        while true {
            let pending = try await database.writer.read { connection in try DuplicateFinder.filesAwaitingCheck(in: connection, mode: mode) }
            guard !pending.isEmpty else { return }
            for start in stride(from: 0, to: pending.count, by: Self.saveBatchSize) {
                let batch = Array(pending[start ..< min(start + Self.saveBatchSize, pending.count)])
                try await verify(batch, kind: mode.digestKind)
                try Task.checkCancellation()
            }
        }
    }

    /// Drops cached rows the next check must redo: transient failures,
    /// rows whose nanosecond mtime or ctime no longer match the live file,
    /// and rows that can't be read back.
    private func revalidate(mode: DuplicateFinder.Mode) async throws {
        let kind = mode.digestKind
        let cached = try await database.writer.read { connection in try DuplicateFinder.filesWithCachedCheck(in: connection, mode: mode) }
        let stale = cached.compactMap { entry -> Int64? in
            let evidence = try? DuplicateDigestStore.evidence(from: entry.row, kind: kind)
            if case .unreadable(_, true) = evidence {
                return entry.candidate.fileID
            }
            guard evidence != nil, let basis = DuplicateDigestStore.basis(from: entry.row),
                  let live = try? AudioFileReadIdentity.read(at: entry.candidate.path).target, basis.matches(live)
            else { return entry.candidate.fileID }
            return nil
        }
        try await database.writer.write { connection in try DuplicateDigestStore.delete(fileIDs: stale, kind: kind, in: connection) }
    }

    /// Checks `candidates` and saves every completed result, even when the
    /// check is cancelled part-way, before cancellation is rethrown.
    func verify(_ candidates: [DigestCandidate], kind: DigestKind) async throws {
        let audioDigest = audioDigest
        let contentDigest = contentDigest
        let results = await withTaskGroup(of: DigestResult?.self) { group in
            var iterator = candidates.makeIterator()
            func addNext() {
                guard let candidate = iterator.next() else { return }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return Self.check(candidate, kind: kind, audioDigest: audioDigest, contentDigest: contentDigest)
                }
            }
            for _ in 0 ..< concurrency {
                addNext()
            }
            var results: [DigestResult] = []
            while let result = await group.next() {
                if let result {
                    results.append(result)
                }
                addNext()
            }
            return results
        }
        try await database.writer.write { connection in try DuplicateDigestStore.save(results, kind: kind, in: connection) }
        try Task.checkCancellation()
    }

    /// The live file must match the indexed basis before reading and stay
    /// unchanged through the read, or the digest describes other bytes.
    private static func check(_ candidate: DigestCandidate, kind: DigestKind, audioDigest: AudioDigestFunction,
                              contentDigest: ContentDigestFunction) -> DigestResult
    {
        func result(_ evidence: DuplicateEvidence, live: SeratoSourceIdentity?) -> DigestResult {
            let basis = live.map { live in DigestBasis(indexed: candidate, live: live) }
                ?? DigestBasis(fileSize: candidate.fileSize, mtime: candidate.mtime, inode: candidate.inode,
                               modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)
            return DigestResult(fileID: candidate.fileID, basis: basis, evidence: evidence)
        }
        let before: AudioFileReadIdentity
        do {
            before = try AudioFileReadIdentity.read(at: candidate.path)
        } catch {
            return result(.unreadable(reason: "Couldn't read the file: \(error.localizedDescription)", retryable: true), live: nil)
        }
        let live = before.target
        guard live.size == candidate.fileSize, Int64(live.modifiedSeconds) == candidate.mtime, Int64(bitPattern: live.inode) == candidate.inode else {
            return result(.unreadable(reason: "The file changed on disk after the last library scan.", retryable: true), live: live)
        }
        let evidence: DuplicateEvidence
        do {
            switch kind {
            case .content:
                evidence = try .content(contentDigest(candidate.path))
            case .audio:
                guard let audio = try DuplicateEvidence.DecodedAudio(audioDigest(candidate.path)) else {
                    return result(.unreadable(reason: "The decoder reported no sample rate.", retryable: false), live: live)
                }
                evidence = .decoded(audio)
            }
        } catch let CoreError.Fingerprint(message) {
            return result(.unreadable(reason: "Couldn't decode the audio: \(message)", retryable: false), live: live)
        } catch {
            return result(.unreadable(reason: "Couldn't read the file: \(error.localizedDescription)", retryable: true), live: live)
        }
        do {
            try before.requireUnchanged(at: candidate.path)
        } catch {
            return result(.unreadable(reason: "The file changed on disk while it was being checked.", retryable: true), live: live)
        }
        return result(evidence, live: live)
    }
}

extension DuplicateEvidenceVerifier {
    /// Caches the decoded-audio digest of a file just confirmed to be its
    /// row's recording, so a later tag-only edit can be told apart from a
    /// replacement (`decodesToIndexedAudio`).
    func recordIndexedAudio(of record: FileRecord) async throws {
        guard let fileID = record.id else { return }
        switch try await indexedAudio(of: record) {
        case .decoded, .unreadable(_, retryable: false): return
        case .pending, .unreadable, .content: break
        }
        try await verify([DigestCandidate(fileID: fileID, path: record.path, fileSize: record.fileSize, mtime: record.mtime, inode: record.inode)],
                         kind: .audio)
    }

    /// Whether the file now at `record.path` decodes to exactly the PCM
    /// cached for the row's indexed identity. A tag edit rewrites bytes, not
    /// audio; only identical PCM proves the recording is unchanged, so a
    /// file with no cached digest, or one that fails to decode, is not.
    func decodesToIndexedAudio(_ record: FileRecord) async throws -> Bool {
        let indexed = try await indexedAudio(of: record)
        guard case .decoded = indexed else { return false }
        let audioDigest = audioDigest
        let path = record.path
        let live = await Task.detached { () -> DuplicateEvidence? in
            guard let before = try? AudioFileReadIdentity.read(at: path),
                  let audio = try? DuplicateEvidence.DecodedAudio(audioDigest(path)),
                  (try? before.requireUnchanged(at: path)) != nil
            else { return nil }
            return .decoded(audio)
        }.value
        guard let live else { return false }
        return DuplicateEvidence.relation(indexed, live) == .identical
    }

    private func indexedAudio(of record: FileRecord) async throws -> DuplicateEvidence {
        guard let fileID = record.id else { return .pending }
        return try await database.writer.read { connection in
            guard let row = try Row.fetchOne(connection, sql: """
            SELECT \(DuplicateDigestStore.columnsSQL(.audio)) FROM files \(DuplicateDigestStore.freshJoinSQL(.audio))
            WHERE files.id = ? AND files.file_size = ? AND files.mtime = ? AND files.inode = ?
            """, arguments: [fileID, record.fileSize, record.mtime, record.inode]) else { return .pending }
            return try DuplicateDigestStore.evidence(from: row, kind: .audio)
        }
    }
}
