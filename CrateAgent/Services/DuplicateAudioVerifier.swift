import Foundation

/// Computes decoded-audio digests lazily, only for files in perceptual
/// duplicate clusters, with bounded concurrency off the main thread. Each
/// result is cached against the size, mtime and inode it was computed from.
public actor DuplicateAudioVerifier {
    public typealias DigestFunction = @Sendable (String) throws -> DecodedAudioDigest

    private let database: LibraryDatabase
    private let concurrency: Int
    private let digestFunction: DigestFunction
    private var isRunning = false
    private static let saveBatchSize = 32

    public init(
        database: LibraryDatabase,
        concurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount / 4),
        digestFunction: @escaping DigestFunction = { path in try decodedAudioDigest(filePath: path) }
    ) {
        self.database = database
        self.concurrency = max(1, concurrency)
        self.digestFunction = digestFunction
    }

    /// Checks every cluster member without a current digest, repeating until
    /// none remain so members that appear mid-pass are covered too. A call
    /// made while a pass runs returns 0 at once. Returns how many files were
    /// checked.
    @discardableResult
    public func verifyPendingFiles() async throws -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }
        var checked = 0
        while true {
            let pending = try await database.writer.read { connection in try DuplicateFinder.filesAwaitingAudioCheck(in: connection) }
            guard !pending.isEmpty else { return checked }
            for start in stride(from: 0, to: pending.count, by: Self.saveBatchSize) {
                try Task.checkCancellation()
                let batch = Array(pending[start ..< min(start + Self.saveBatchSize, pending.count)])
                let results = try await check(batch)
                try await database.writer.write { connection in try AudioDigestStore.save(results, in: connection) }
                checked += results.count
            }
        }
    }

    private func check(_ files: [(fileID: Int64, path: String, basis: AudioDigestBasis)]) async throws -> [AudioDigestResult] {
        let digestFunction = digestFunction
        return try await withThrowingTaskGroup(of: AudioDigestResult.self) { group in
            var iterator = files.makeIterator()
            func addNext() {
                guard let file = iterator.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    return AudioDigestResult(fileID: file.fileID, basis: file.basis,
                                             evidence: Self.evidence(path: file.path, basis: file.basis, digestFunction: digestFunction))
                }
            }
            for _ in 0 ..< concurrency {
                addNext()
            }
            var results: [AudioDigestResult] = []
            while let result = try await group.next() {
                results.append(result)
                addNext()
            }
            return results
        }
    }

    /// The live file must match the indexed basis before decoding and stay
    /// unchanged through the decode, or the digest describes other bytes.
    private static func evidence(path: String, basis: AudioDigestBasis, digestFunction: DigestFunction) -> DuplicateAudioEvidence {
        do {
            let before = try AudioFileReadIdentity.read(at: path)
            guard let live = FileMetadataCollector.collect(at: path), AudioDigestBasis(live) == basis else {
                return .unreadable("The file changed on disk after the last library scan.")
            }
            let digest = try digestFunction(path)
            do {
                try before.requireUnchanged(at: path)
            } catch {
                return .unreadable("The file changed on disk while its audio was being checked.")
            }
            guard digest.sampleRate > 0 else { return .unreadable("The decoder reported no sample rate.") }
            return .decoded(.init(format: digest.format, pcmDigest: digest.pcmSha256, fullFingerprintDigest: digest.fullFingerprintSha256,
                                  durationSeconds: Double(digest.frameCount) / Double(digest.sampleRate)))
        } catch {
            return .unreadable("Couldn't decode the audio: \(error.localizedDescription)")
        }
    }
}
