import Foundation

public extension OperationEngine {
    /// A user's edit of a file's metadata: the database row (`setMetadata`),
    /// Serato's database V2 (`commitMetadataToSerato`) and the audio file's
    /// tags (`writeFileTags`), in one batch so one Undo from History reverts
    /// all three. The Serato and tag writes queue while Serato runs. Each
    /// carries `previous`, so each is invertible; the engine refuses the edit
    /// with `metadataChanged` when the live row no longer holds `previous`.
    func applyMetadataEdit(
        fileId: Int64,
        membershipRevision: Int64,
        previous: SeratoMetadata,
        edited: SeratoMetadata,
        batchId: String
    ) async throws {
        try await applyBatch(
            [
                .setMetadata(SetMetadataPayload(fileId: fileId, metadata: edited, isSeratoAuthoritative: false)),
                .commitMetadataToSerato(CommitMetadataToSeratoPayload(fileId: fileId, metadata: edited, previousMetadata: previous)),
                .writeFileTags(WriteFileTagsPayload(fileId: fileId, metadata: edited, previousMetadata: previous)),
            ],
            batchId: batchId,
            expectedMembershipTokens: [fileId: FileMembershipToken(fileId: fileId, revision: membershipRevision)],
            expectedMetadata: [fileId: previous]
        )
    }
}
