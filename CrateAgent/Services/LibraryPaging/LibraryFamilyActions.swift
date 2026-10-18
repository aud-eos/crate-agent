import Foundation

/// Song-family commands offered on a Library row.
enum LibraryFamilyAction: CaseIterable, Sendable {
    case groupSelected, addSelected, mergeSelected, splitSelected, setMain, automaticMain, remove

    var title: String {
        switch self {
        case .groupSelected: LibraryFamilyMessages.groupSelected
        case .addSelected: LibraryFamilyMessages.addSelected
        case .mergeSelected: LibraryFamilyMessages.mergeSelected
        case .splitSelected: LibraryFamilyMessages.splitSelected
        case .setMain: LibraryFamilyMessages.setMain
        case .automaticMain: LibraryFamilyMessages.automaticMain
        case .remove: LibraryFamilyMessages.remove
        }
    }

    /// Whether the action applies to the clicked `row` when `targetCount` files are targeted.
    func applies(to row: BrowserRow, targetCount: Int) -> Bool {
        let inFamily = row.familyId != nil && row.recordingId != nil
        return switch self {
        case .groupSelected: targetCount >= 2
        case .addSelected, .mergeSelected, .splitSelected: inFamily && targetCount >= 2
        case .setMain: inFamily && row.savedMain != true
        case .automaticMain: inFamily && row.savedMain == true
        case .remove: inFamily
        }
    }
}

/// What a family command acts on: the clicked row, and the files it targets.
/// The files are the selection when the clicked row is selected, else the row
/// alone, each at the revision the user saw.
struct LibraryFamilyActionTarget: Sendable {
    let clicked: BrowserRow
    let files: [PagedIdentity<Int64>]
}

enum LibraryFamilyActionError: LocalizedError, Equatable {
    case nothingToChange
    case notInFamily

    var errorDescription: String? {
        switch self {
        case .nothingToChange: LibraryFamilyMessages.nothingToChange
        case .notInFamily: LibraryFamilyMessages.notInFamily
        }
    }
}

/// Runs Library's family commands through `SongFamilyService`. Every targeted
/// file is passed as authority, so a file whose membership changed after it
/// was shown refuses the whole change instead of being regrouped.
struct LibraryFamilyActions: Sendable {
    let families: SongFamilyService

    @discardableResult
    func perform(_ action: LibraryFamilyAction, on target: LibraryFamilyActionTarget) async throws -> SongFamilyResult {
        let authority = target.files.map { identity in FileMembershipToken(fileId: identity.id, revision: identity.revision) }
        switch action {
        case .groupSelected:
            return try await families.create(target.files.map { identity in .file(identity.id) }, authority: authority)
        case .setMain, .automaticMain:
            let (familyID, recording) = try family(of: target.clicked)
            let clicked = FileMembershipToken(fileId: target.clicked.id, revision: target.clicked.membershipRevision)
            return try await families.setRepresentative(action == .setMain ? recording : nil, of: familyID, authority: [clicked])
        case .addSelected:
            let (familyID, memberships) = try await memberships(of: target)
            let outside = memberships.filter { membership in membership.familyId != familyID }
            guard !outside.isEmpty else { throw LibraryFamilyActionError.nothingToChange }
            return try await families.attach(outside.map { membership in .file(membership.fileId) }, to: familyID, authority: authority)
        case .mergeSelected:
            let (familyID, memberships) = try await memberships(of: target)
            let others = Set(memberships.compactMap(\.familyId)).subtracting([familyID])
            guard !others.isEmpty else { throw LibraryFamilyActionError.nothingToChange }
            return try await families.merge(others.sorted(), into: familyID, authority: authority)
        case .splitSelected:
            let (familyID, memberships) = try await memberships(of: target)
            return try await families.split(recordings(in: familyID, memberships), from: familyID, authority: authority)
        case .remove:
            let (familyID, memberships) = try await memberships(of: target)
            let recordings = recordings(in: familyID, memberships)
            guard !recordings.isEmpty else { throw LibraryFamilyActionError.nothingToChange }
            return try await families.detach(recordings, from: familyID, authority: authority)
        }
    }

    private func family(of row: BrowserRow) throws -> (familyId: Int64, recordingId: Int64) {
        guard let familyID = row.familyId, let recording = row.recordingId else { throw LibraryFamilyActionError.notInFamily }
        return (familyID, recording)
    }

    private func memberships(of target: LibraryFamilyActionTarget) async throws -> (familyId: Int64, [SongFamilyFileMembership]) {
        let (familyID, _) = try family(of: target.clicked)
        return try await (familyID, families.memberships(ofFiles: target.files.map(\.id)))
    }

    private func recordings(in familyID: Int64, _ memberships: [SongFamilyFileMembership]) -> [Int64] {
        Set(memberships.filter { membership in membership.familyId == familyID }.compactMap(\.trackId)).sorted()
    }
}
