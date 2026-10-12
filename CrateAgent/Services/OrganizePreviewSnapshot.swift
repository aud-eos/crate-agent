import Foundation
import GRDB
import os

struct OrganizePlanningCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        cancelled.withLock { cancelled in cancelled = true }
    }

    func check() throws {
        if cancelled.withLock({ cancelled in cancelled }) {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }
}

struct OrganizePreviewSnapshot: Sendable {
    struct Row: Identifiable, Sendable {
        enum Disposition: Sendable {
            case move(LibraryOrganizer.Plan)
            case needsMetadata([SeratoMetadataField])
            case pathConflict(String)
        }

        let id: Int64
        let sourcePath: String
        let isOutsideMusicFolder: Bool
        let artist: String
        let title: String
        let searchText: String
        let disposition: Disposition

        var plan: LibraryOrganizer.Plan? {
            guard case let .move(plan) = disposition else { return nil }
            return plan
        }

        var status: String {
            switch disposition {
            case .move: return "Ready"
            case let .pathConflict(reason): return reason
            case let .needsMetadata(fields): return OrganizeMessages.needsMetadata(fields)
            }
        }
    }

    let generation = UUID()
    let rows: [Row]
    let indexesByID: [Int64: Int]
    let outsideIndexes: [Int]
    let outsideScope: IndexSet
    let allScope: IndexSet
    let selection: BatchSelection
    let droppedSelectionCount: Int

    var blockedCount: Int {
        rows.count - allScope.count
    }

    static let empty = OrganizePreviewSnapshot(rows: [], indexesByID: [:], outsideIndexes: [], outsideScope: [], allScope: [], selection: BatchSelection(), droppedSelectionCount: 0)

    static func load(database: LibraryDatabase, musicFolder: URL, template: String,
                     previous: OrganizePreviewSnapshot, selected: BatchSelection,
                     cancellation: OrganizePlanningCancellation, readiness: LibrarySyncReadiness? = nil) async throws -> OrganizePreviewSnapshot
    {
        let files = try await database.writer.read { connection in
            var files: [HygieneFileRow] = []
            let cursor = try HygieneFileRow.fetchCursor(connection, sql: HygieneFileRow.hygieneFetchSQL + " ORDER BY id")
            while let file = try cursor.next() {
                try cancellation.check()
                files.append(file)
            }
            return files
        }
        let preview = try LibraryOrganizer.preview(in: files, musicFolder: musicFolder, template: template, readiness: readiness, checkCancellation: cancellation.check)
        let plansByID = Dictionary(uniqueKeysWithValues: preview.plans.map { plan in (plan.id, plan) })
        let blockedByID = Dictionary(uniqueKeysWithValues: preview.blockedFiles.map { file in (file.id, file) })
        var rows: [Row] = []
        var indexesByID: [Int64: Int] = [:]
        var outsideIndexes: [Int] = []
        var outsideScope = IndexSet()
        var allScope = IndexSet()
        for file in files {
            try cancellation.check()
            guard let identifier = file.id else { continue }
            let disposition: Row.Disposition
            let isOutside: Bool
            if let plan = plansByID[identifier] {
                disposition = .move(plan)
                isOutside = plan.isOutsideMusicFolder
            } else if let blocked = blockedByID[identifier] {
                disposition = blocked.conflictReason.map(Row.Disposition.pathConflict) ?? .needsMetadata(blocked.missingFields)
                isOutside = blocked.isOutsideMusicFolder
            } else {
                continue
            }
            let index = rows.count
            indexesByID[identifier] = index
            rows.append(Row(id: identifier, sourcePath: file.path, isOutsideMusicFolder: isOutside,
                            artist: LibraryHygiene.isMissing(file.artist) ? OrganizeMessages.noValue : file.artist ?? "",
                            title: LibraryHygiene.isMissing(file.title) ? (file.path as NSString).lastPathComponent : file.title ?? "",
                            searchText: ListSearch.normalized(ListSearch.text(artist: file.artist, title: file.title, album: file.album, path: file.path)),
                            disposition: disposition))
            if isOutside {
                outsideIndexes.append(index)
            }
            if case .move = disposition {
                allScope.insert(index)
                if isOutside {
                    outsideScope.insert(index)
                }
            }
        }
        var reconciled = BatchSelection()
        for oldIndex in selected.indexes {
            try cancellation.check()
            guard let oldPlan = previous.rows[oldIndex].plan else { preconditionFailure("Blocked rows cannot be selected") }
            if let index = indexesByID[oldPlan.id], rows[index].plan == oldPlan {
                reconciled.set(true, at: index)
            }
        }
        return OrganizePreviewSnapshot(rows: rows, indexesByID: indexesByID, outsideIndexes: outsideIndexes,
                                       outsideScope: outsideScope, allScope: allScope,
                                       selection: reconciled, droppedSelectionCount: selected.count - reconciled.count)
    }
}
