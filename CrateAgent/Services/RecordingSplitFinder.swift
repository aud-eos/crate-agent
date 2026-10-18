import Foundation
import GRDB

/// Files whose 120 s fingerprints collide, so they share one recording
/// identity, but whose full-length fingerprints differ (#205). Read-only: it
/// previews which files would get a recording of their own, and which
/// existing recording links that changes, before anything is written.
public struct RecordingSplitScan: Sendable, Equatable {
    public let candidates: [RecordingSplitCandidate]
    /// Collisions with a file whose full-length fingerprint is still being
    /// computed, so whether they differ isn't known yet.
    public let checkingCount: Int
}

/// One 120 s fingerprint shared by audio that differs over its full length.
/// `keeps` stays the shared recording; each version in `separates` gets a
/// recording of its own.
public struct RecordingSplitCandidate: Sendable, Equatable, Identifiable {
    public let fingerprintHash: Data
    public let keeps: RecordingSplitVersion
    public let separates: [RecordingSplitVersion]

    public var id: String {
        fingerprintHash.lowercaseHex
    }

    /// Files whose current recording link moves; the rest only stop being
    /// identified with the shared recording.
    public var movedFiles: [RecordingSplitFile] {
        separates.flatMap(\.files).filter { file in file.sharedRecording != nil }
    }
}

/// Files whose full-length fingerprints are identical.
public struct RecordingSplitVersion: Sendable, Equatable {
    public let fullFingerprintDigest: Data
    public let files: [RecordingSplitFile]
}

public struct RecordingSplitFile: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let membershipRevision: Int64
    public let name: String
    public let path: String
    /// The shared recording the file is linked to now, which a separated
    /// file leaves along with its MusicBrainz match and song family.
    public let sharedRecording: SharedRecording?

    public struct SharedRecording: Sendable, Equatable {
        public let trackId: Int64
        public let hasMusicBrainzMatch: Bool
        public let isInSongFamily: Bool
    }
}

enum RecordingSplitFinder {
    /// What a scan reads of each colliding file, without decoding a whole `FileRecord`.
    private struct Member {
        let id: Int64
        let membershipRevision: Int64
        let name: String
        let path: String
        let trackID: Int64?
        let evidence: DuplicateEvidence

        init(row: Row) throws {
            id = row["id"]
            membershipRevision = row["membership_revision"]
            path = row["path"]
            trackID = row["track_id"]
            let title: String? = row["title"]
            name = title.flatMap { title in title.isEmpty ? nil : title } ?? (path as NSString).lastPathComponent
            evidence = try DuplicateDigestStore.evidence(from: row, kind: .audio)
        }
    }

    static func scan(in database: Database) throws -> RecordingSplitScan {
        var membersByHash: [Data: [Member]] = [:]
        let rows = try Row.fetchCursor(database, sql: """
        SELECT \(fileColumnsSQL), \(DuplicateDigestStore.columnsSQL(.audio)), separation.fingerprint_sha256 AS separation_hash
        FROM files
        \(DuplicateDigestStore.freshJoinSQL(.audio))
        LEFT JOIN \(RecordingIdentity.table) AS separation ON separation.file_id = files.id
        WHERE \(DuplicateFinder.clusterMemberSQL(.perceptual))
        ORDER BY files.id
        """)
        while let row = try rows.next() {
            guard let status = FingerprintStatus(rawValue: row["fingerprint_status"]),
                  let hash = RecordingIdentity.fingerprintHash(row["chromaprint_fingerprint"], status: status,
                                                               fingerprintedSize: row["fingerprinted_size"], fingerprintedMtime: row["fingerprinted_mtime"],
                                                               fileSize: row["file_size"], mtime: row["mtime"]),
                  row["separation_hash"] as Data? != hash
            else { continue }
            try membersByHash[hash, default: []].append(Member(row: row))
        }
        let sharedTracks = try TrackRecord.filter(membersByHash.keys.contains(Column("fingerprint_hash"))).fetchAll(database)
        let sharedTrackByHash = Dictionary(sharedTracks.map { track in (track.fingerprintHash, track) }, uniquingKeysWith: { first, _ in first })
        var candidates: [RecordingSplitCandidate] = []
        var checkingCount = 0
        for (hash, members) in membersByHash where members.count > 1 {
            guard !members.contains(where: { member in member.evidence.isPending }) else {
                checkingCount += 1
                continue
            }
            let versions = Dictionary(grouping: members.compactMap { member -> (digest: Data, member: Member)? in
                guard case let .decoded(audio) = member.evidence else { return nil }
                return (audio.fullFingerprintDigest, member)
            }, by: \.digest)
            guard versions.count > 1 else { continue }
            let shared = sharedTrackByHash[hash]
            let ranked = versions.map { digest, entries in
                RecordingSplitVersion(fullFingerprintDigest: digest, files: entries.map { entry in splitFile(entry.member, shared: shared) })
            }.sorted(by: keepsBefore)
            candidates.append(RecordingSplitCandidate(fingerprintHash: hash, keeps: ranked[0], separates: Array(ranked.dropFirst())))
        }
        candidates.sort { lhs, rhs in (lhs.keeps.files.first?.id ?? 0) < (rhs.keeps.files.first?.id ?? 0) }
        return RecordingSplitScan(candidates: candidates, checkingCount: checkingCount)
    }

    private static let fileColumnsSQL = """
    files.id, files.path, files.file_size, files.mtime, files.title, files.track_id, files.membership_revision,
    files.chromaprint_fingerprint, files.fingerprint_status, files.fingerprinted_size, files.fingerprinted_mtime
    """

    /// The version with the most files linked to the shared recording keeps
    /// it, so the fewest links move; ties go to the version with the oldest file.
    private static func keepsBefore(_ lhs: RecordingSplitVersion, _ rhs: RecordingSplitVersion) -> Bool {
        let lhsLinked = lhs.files.count(where: { file in file.sharedRecording != nil })
        let rhsLinked = rhs.files.count(where: { file in file.sharedRecording != nil })
        if lhsLinked != rhsLinked {
            return lhsLinked > rhsLinked
        }
        return (lhs.files.map(\.id).min() ?? 0) < (rhs.files.map(\.id).min() ?? 0)
    }

    private static func splitFile(_ member: Member, shared: TrackRecord?) -> RecordingSplitFile {
        let linked = shared.flatMap { track -> RecordingSplitFile.SharedRecording? in
            guard let trackID = track.id, member.trackID == trackID else { return nil }
            return .init(trackId: trackID, hasMusicBrainzMatch: track.hasRecordingIdentity, isInSongFamily: track.workId != nil)
        }
        return RecordingSplitFile(id: member.id, membershipRevision: member.membershipRevision, name: member.name, path: member.path,
                                  sharedRecording: linked)
    }

    /// The file's cached full-length fingerprint digest, while the cache
    /// still describes its indexed size, mtime and inode.
    static func fullFingerprintDigest(of file: FileRecord, in database: Database) throws -> Data? {
        try Data.fetchOne(database, sql: """
        SELECT digest.full_fingerprint_sha256 FROM files \(DuplicateDigestStore.freshJoinSQL(.audio)) WHERE files.id = ?
        """, arguments: [file.id])
    }

    /// Whether another processable file still shares `file`'s recording by
    /// its 120 s fingerprint while its full-length fingerprint differs. Only
    /// colliding files have digests, so the scan starts from the digest cache.
    static func sharesFingerprintWithDifferentAudio(_ file: FileRecord, fingerprintHash: Data, fullFingerprintDigest: Data,
                                                    in database: Database) throws -> Bool
    {
        let others = try FileRecord.fetchAll(database, sql: """
        SELECT files.* FROM file_audio_digests AS digest
        CROSS JOIN files ON files.id = digest.file_id
          AND digest.file_size = files.file_size AND digest.mtime = files.mtime AND digest.inode = files.inode
        LEFT JOIN \(RecordingIdentity.table) AS separation ON separation.file_id = files.id AND separation.fingerprint_sha256 = ?
        WHERE files.id != ? AND \(FileProcessingEligibility.processableSQL) AND files.chromaprint_fingerprint = ?
          AND separation.file_id IS NULL AND digest.full_fingerprint_sha256 != ?
        """, arguments: [fingerprintHash, file.id, file.chromaprintFingerprint, fullFingerprintDigest])
        return others.contains { other in RecordingIdentity.fingerprintHash(of: other) == fingerprintHash }
    }
}

/// Splitting one recording identity that a 120 s fingerprint collision
/// merged, and the full-length fingerprint pass it needs. Splits are explicit:
/// the preview names every recording link that moves, and the user applies
/// it as one undoable History batch.
public struct RecordingIdentityService: Sendable {
    private let engine: OperationEngine
    private let writer: any DatabaseWriter
    private let verifier: DuplicateEvidenceVerifier

    public init(engine: OperationEngine, database: LibraryDatabase, verifier: DuplicateEvidenceVerifier) {
        self.engine = engine
        writer = database.writer
        self.verifier = verifier
    }

    /// Computes the full-length fingerprint of every file whose 120 s
    /// fingerprint collides and has no current one: the same digests the
    /// perceptual duplicate check uses.
    public func checkCollidingFiles() async throws {
        try await verifier.verifyPendingFiles(mode: .perceptual)
    }

    public func scan() async throws -> RecordingSplitScan {
        try await writer.read { database in try RecordingSplitFinder.scan(in: database) }
    }

    /// Gives each version in `candidate.separates` its own recording, as
    /// previewed. A file that changed since the scan refuses the whole split.
    @discardableResult
    public func separate(_ candidate: RecordingSplitCandidate) async throws -> String {
        let batchID = "recording-split-\(UUID().uuidString)"
        let separations = candidate.separates.flatMap { version in
            version.files.map { file in
                TrackMutation.recordingIdentity(.separate(.fullFingerprint(
                    fileId: file.id, membershipRevision: file.membershipRevision, fingerprintHash: candidate.fingerprintHash,
                    fullFingerprintDigest: version.fullFingerprintDigest
                )))
            }
        }
        _ = try await engine.applyBatch(separations, batchId: batchID)
        return batchID
    }
}
