import Foundation
import GRDB

/// One row in the `works` table: a user-curated song family. Members are the
/// `tracks` rows whose `work_id` names it; each recording belongs to at most
/// one family. `representativeTrackId` is the saved manual preference only;
/// the displayed representative is chosen by `SongFamilyRepresentative`.
public struct SongFamilyRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Identifiable, Sendable {
    public static let databaseTableName = "works"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var representativeTrackId: Int64?

    public init(id: Int64? = nil, representativeTrackId: Int64? = nil) {
        self.id = id
        self.representativeTrackId = representativeTrackId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
