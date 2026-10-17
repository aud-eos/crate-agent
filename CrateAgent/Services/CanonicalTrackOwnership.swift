import Foundation
import GRDB

/// Which MusicBrainz match owns each field of a fingerprint-keyed canonical
/// track row, so undoing one match restores only what it still owns (#113).
///
/// Every match that writes a row journals its event against that row with the
/// row's prior values. A match is live while its file's match history, read as
/// a stack (apply pushes, revert pops), still holds it. History is grouped by
/// the payload's file, not `events.file_id`, so a removed file's matches stay
/// live (#112). Undoing a live match restores a field it wrote only if no
/// later live match also wrote that field. The restored value is the row's
/// value before the oldest writer after the latest earlier live writer of that
/// field, which skips writers that were undone while a later one kept the field.
enum CanonicalTrackOwnership {
    private struct Writer {
        let eventID: Int64
        let fileID: Int64
        let isLive: Bool
        let previous: TrackIdentifiers
        let wroteDisplay: DisplayFields

        struct DisplayFields {
            let artist: Bool
            let title: Bool
            let album: Bool
            let year: Bool
        }
    }

    /// Restores on `track` the fields undoing `fileID`'s live match must
    /// restore, before that undo is journaled.
    static func restoreFields(of track: inout TrackRecord, revertingMatchOf fileID: Int64, in database: Database) throws {
        guard let trackID = track.id else { throw OperationEngineError.matchOwnershipNotFound(fileId: fileID) }
        let writers = try writers(ofTrack: trackID, in: database)
        guard let reverted = writers.last(where: { writer in writer.fileID == fileID && writer.isLive }) else {
            throw OperationEngineError.matchOwnershipNotFound(fileId: fileID)
        }
        restore(&track, reverting: reverted, writers: writers)
    }

    private static func writers(ofTrack trackID: Int64, in database: Database) throws -> [Writer] {
        let decoder = JSONDecoder()
        let applies = try EventRecord
            .filter(Column("track_id") == trackID && Column("event_type") == EventType.musicBrainzMatchApplied.rawValue)
            .order(Column("event_id"))
            .fetchAll(database)
        let decodedApplies = try applies.map { event in try (event, decode(ApplyMusicBrainzMatchPayload.self, from: event, decoder: decoder)) }
        let live = try liveApplyEventIDs(fileIDs: Set(decodedApplies.map { _, payload in payload.fileID }), in: database, decoder: decoder)
        return decodedApplies.compactMap { event, payload in
            guard let eventID = event.eventId else { return nil }
            return writer(eventID: eventID, payload: payload, isLive: live.contains(eventID))
        }
    }

    private static func restore(_ track: inout TrackRecord, reverting reverted: Writer, writers: [Writer]) {
        func restored<Value>(_ field: KeyPath<TrackIdentifiers, Value?>, wrote: (Writer) -> Bool) -> Value?? {
            guard wrote(reverted) else { return nil }
            let fieldWriters = writers.filter(wrote)
            guard let position = fieldWriters.firstIndex(where: { writer in writer.eventID == reverted.eventID }),
                  !fieldWriters[(position + 1)...].contains(where: \.isLive)
            else { return nil }
            let earlier = fieldWriters[..<position]
            let firstUnowned = earlier.lastIndex(where: \.isLive).map { index in index + 1 } ?? earlier.startIndex
            return .some(fieldWriters[firstUnowned].previous[keyPath: field])
        }
        let identity: (Writer) -> Bool = { _ in true }
        if let value = restored(\.acoustID, wrote: identity) {
            track.acoustidId = value
        }
        if let value = restored(\.recordingMBID, wrote: identity) {
            track.musicbrainzRecordingId = value
        }
        if let value = restored(\.releaseMBID, wrote: identity) {
            track.musicbrainzReleaseId = value
        }
        if let value = restored(\.artistMBID, wrote: identity) {
            track.musicbrainzArtistId = value
        }
        if let value = restored(\.isrc, wrote: identity) {
            track.isrc = value
        }
        if let value = restored(\.artist, wrote: \.wroteDisplay.artist) {
            track.artist = value
        }
        if let value = restored(\.title, wrote: \.wroteDisplay.title) {
            track.title = value
        }
        if let value = restored(\.album, wrote: \.wroteDisplay.album) {
            track.album = value
        }
        if let value = restored(\.year, wrote: \.wroteDisplay.year) {
            track.year = value
        }
    }

    private static let emptyIdentifiers = TrackIdentifiers(acoustID: nil, recordingMBID: nil, releaseMBID: nil, artistMBID: nil, isrc: nil,
                                                           artist: nil, title: nil, album: nil, year: nil)

    private static func writer(eventID: Int64, payload: ApplyMusicBrainzMatchPayload, isLive: Bool) -> Writer {
        let previous = payload.previousTrackIdentifiers ?? emptyIdentifiers
        // The forward seeds kept display fields into a row it creates or an
        // unreferenced empty row it reuses. The payload doesn't record the
        // reuse, so any empty prior row counts; for a referenced one this only
        // restores a field the forward left empty to empty.
        let seeded = payload.createdTrackRow || previous == emptyIdentifiers
        func wrote<Value>(_ chosen: Value?, kept: Value?) -> Bool {
            chosen != nil || (seeded && kept != nil)
        }
        return Writer(eventID: eventID, fileID: payload.fileID, isLive: isLive, previous: previous,
                      wroteDisplay: .init(artist: wrote(payload.artist, kept: payload.currentFileArtist),
                                          title: wrote(payload.title, kept: payload.currentFileTitle),
                                          album: wrote(payload.album, kept: payload.currentFileAlbum),
                                          year: wrote(payload.year, kept: payload.currentFileYear)))
    }

    /// Match events are read for the files themselves and for removed files,
    /// whose events no longer carry a `file_id`; a reused file ID stays apart
    /// from the removed file that held it before.
    private static func liveApplyEventIDs(fileIDs: Set<Int64>, in database: Database, decoder: JSONDecoder) throws -> Set<Int64> {
        guard !fileIDs.isEmpty else { return [] }
        let matchTypes = [EventType.musicBrainzMatchApplied.rawValue, EventType.musicBrainzMatchReverted.rawValue]
        let history = try EventRecord
            .filter(matchTypes.contains(Column("event_type")))
            .filter(fileIDs.contains(Column("file_id")) || Column("file_id") == nil)
            .order(Column("event_id"))
            .fetchAll(database)
        struct HistoryKey: Hashable {
            let fileID: Int64
            let removed: Bool
        }
        var stacks: [HistoryKey: [Int64]] = [:]
        for event in history {
            guard let eventID = event.eventId else { continue }
            if event.eventType == .musicBrainzMatchApplied {
                let payload = try decode(ApplyMusicBrainzMatchPayload.self, from: event, decoder: decoder)
                stacks[HistoryKey(fileID: payload.fileID, removed: event.fileId == nil), default: []].append(eventID)
            } else {
                let payload = try decode(RevertMusicBrainzMatchPayload.self, from: event, decoder: decoder)
                let key = HistoryKey(fileID: payload.applied.fileID, removed: event.fileId == nil)
                _ = stacks[key]?.popLast()
            }
        }
        return Set(stacks.values.joined())
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from event: EventRecord, decoder: JSONDecoder) throws -> Payload {
        do {
            return try decoder.decode(type, from: Data(event.payloadJson.utf8))
        } catch {
            throw OperationEngineError.eventPayloadDecodingFailed(
                eventId: event.eventId, batchId: event.batchId, eventType: event.eventType, underlying: String(describing: error)
            )
        }
    }
}
