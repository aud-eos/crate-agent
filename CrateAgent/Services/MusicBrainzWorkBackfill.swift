import Foundation
import GRDB

/// Records the MusicBrainz work of recordings matched before matches recorded
/// one (#262), as a Workers job. Lookups go through the shared
/// `MusicBrainzClient`, so they share Auto-Tag's one-request-a-second limiter
/// and lookup cache; a stopped run resumes where it stopped, because only
/// recordings still without a work are looked up and those already looked up
/// answer from the cache. Every write is a journaled `recordMusicBrainzWork`
/// mutation, so History shows it and undo reverts it. A work is only ever
/// added where none is recorded, for the recording that was looked up. The
/// run stops on the first error and shows it.
@MainActor
final class MusicBrainzWorkBackfill: ObservableObject {
    struct Progress: Equatable, Sendable {
        var checked = 0
        var total = 0
        /// Recordings given a work so far.
        var recorded = 0
    }

    enum Status: Equatable {
        case idle
        case running(Progress)
        case finished(Progress)
        case cancelled(Progress)
        case failed(Progress, reason: String)
    }

    /// Recordings recorded per History batch, so a long run commits as it
    /// goes and a stop loses at most this many lookups (which the cache keeps).
    static let recordingsPerBatch = 50

    /// A recording still without a work, and the tracks that name it.
    struct PendingRecording: Equatable, Sendable {
        let recordingMBID: String
        let trackIDs: [Int64]
    }

    /// Matched recordings a library file links to; only these are looked up.
    nonisolated static let matchedRecordingSQL = """
    tracks.musicbrainz_recording_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM files WHERE files.track_id = tracks.id AND \(FileProcessingEligibility.activeSQL))
    """

    @Published private(set) var status: Status = .idle

    private let database: LibraryDatabase
    private let engine: OperationEngine
    private let client: MusicBrainzClient
    private var cancelRequested = false
    private var lookup: Task<MBRecording, Error>?

    init(database: LibraryDatabase, engine: OperationEngine, client: MusicBrainzClient) {
        self.database = database
        self.engine = engine
        self.client = client
    }

    var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    /// Runs until every pending recording is checked, `cancel()` stops it,
    /// or an error does. Does nothing while a run is in progress.
    func run() async {
        guard !isRunning else { return }
        cancelRequested = false
        var progress = Progress()
        status = .running(progress)
        var unrecorded: [RecordMusicBrainzWorkPayload] = []
        do {
            let pending = try await database.writer.read { database in try Self.pendingRecordings(in: database) }
            progress.total = pending.count
            status = .running(progress)
            for recording in pending {
                guard !cancelRequested else { break }
                let looked: MBRecording
                do {
                    looked = try await lookUp(recording.recordingMBID)
                } catch where cancelRequested {
                    break
                }
                progress.checked += 1
                if let workMBID = looked.workMBID {
                    unrecorded += recording.trackIDs.map { trackID in
                        RecordMusicBrainzWorkPayload(trackId: trackID, recordingMBID: recording.recordingMBID, workMBID: workMBID, previousWorkMBID: nil)
                    }
                }
                if unrecorded.count >= Self.recordingsPerBatch {
                    try await record(&unrecorded, progress: &progress)
                }
                status = .running(progress)
            }
            try await record(&unrecorded, progress: &progress)
            status = cancelRequested ? .cancelled(progress) : .finished(progress)
        } catch {
            var reason = UserFacingErrorMessage.message(for: error)
            // Works already looked up are still recorded, so a resumed run
            // starts after them; a failure to record them is shown too.
            do {
                try await record(&unrecorded, progress: &progress)
            } catch let recordingError {
                reason += " " + UserFacingErrorMessage.message(for: recordingError)
            }
            status = .failed(progress, reason: reason)
        }
        lookup = nil
    }

    /// Cancels the lookup in flight and ends the run, recording the works
    /// found so far.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        lookup?.cancel()
    }

    private func lookUp(_ recordingMBID: String) async throws -> MBRecording {
        let request = Task { [client] in try await client.recording(mbid: recordingMBID) }
        lookup = request
        return try await request.value
    }

    private func record(_ unrecorded: inout [RecordMusicBrainzWorkPayload], progress: inout Progress) async throws {
        guard !unrecorded.isEmpty else { return }
        let batch = unrecorded
        unrecorded = []
        try await engine.applyBatch(batch.map(TrackMutation.recordMusicBrainzWork), batchId: UUID().uuidString)
        progress.recorded += batch.count
    }

    /// Ordered by first track, so a run's order is stable across resumes.
    nonisolated static func pendingRecordings(in database: Database) throws -> [PendingRecording] {
        let rows = try Row.fetchAll(database, sql: """
        SELECT id, musicbrainz_recording_id FROM tracks WHERE musicbrainz_work_id IS NULL AND \(matchedRecordingSQL) ORDER BY id
        """)
        var recordingOrder: [String] = []
        var tracksByRecording: [String: [Int64]] = [:]
        for row in rows {
            let recordingMBID: String = row["musicbrainz_recording_id"]
            if tracksByRecording[recordingMBID] == nil {
                recordingOrder.append(recordingMBID)
            }
            tracksByRecording[recordingMBID, default: []].append(row["id"])
        }
        return recordingOrder.map { recordingMBID in PendingRecording(recordingMBID: recordingMBID, trackIDs: tracksByRecording[recordingMBID] ?? []) }
    }
}
