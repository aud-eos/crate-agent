import Foundation
import GRDB

/// Records the MusicBrainz work of an already-matched recording, as the
/// work backfill finds it (#262). A match records its work itself; this
/// fills the work of recordings matched before works were recorded. The
/// inverse is the same change the other way round.
public struct RecordMusicBrainzWorkPayload: Codable, Sendable, Equatable {
    public let trackId: Int64
    /// The recording the work was looked up for. The change is refused once
    /// the track names another recording.
    public let recordingMBID: String
    public let workMBID: String?
    public let previousWorkMBID: String?

    public init(trackId: Int64, recordingMBID: String, workMBID: String?, previousWorkMBID: String?) {
        self.trackId = trackId
        self.recordingMBID = recordingMBID
        self.workMBID = workMBID
        self.previousWorkMBID = previousWorkMBID
    }

    var inverse: RecordMusicBrainzWorkPayload {
        RecordMusicBrainzWorkPayload(trackId: trackId, recordingMBID: recordingMBID, workMBID: previousWorkMBID, previousWorkMBID: workMBID)
    }
}

public enum MusicBrainzWorkError: LocalizedError, Equatable {
    /// The recording's match or work changed since the work was looked up or recorded.
    case changedSinceLookup(trackId: Int64)

    public var errorDescription: String? {
        switch self {
        case let .changedSinceLookup(trackId):
            MusicBrainzWorkMessages.changedSinceLookup(trackID: trackId)
        }
    }
}

enum MusicBrainzWorkMutation {
    static func apply(_ payload: RecordMusicBrainzWorkPayload, batchId: String, timestamp: Int64, in database: Database) throws -> Int64 {
        // Rechecked in the transaction: a match or undo since the lookup owns
        // the row now, and a work recorded since is never overwritten.
        guard var track = try TrackRecord.fetchOne(database, key: payload.trackId),
              track.musicbrainzRecordingId == payload.recordingMBID, track.musicbrainzWorkId == payload.previousWorkMBID
        else {
            throw MusicBrainzWorkError.changedSinceLookup(trackId: payload.trackId)
        }
        track.musicbrainzWorkId = payload.workMBID
        try track.update(database)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: nil, trackId: payload.trackId,
                                               eventType: payload.workMBID == nil ? .musicBrainzWorkCleared : .musicBrainzWorkRecorded,
                                               forwardPayload: payload, inversePayload: payload.inverse, in: database)
    }
}
