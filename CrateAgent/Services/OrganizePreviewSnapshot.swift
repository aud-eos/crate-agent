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
        let plan: LibraryOrganizer.Plan
        let artist: String
        let title: String
        var id: Int64 {
            plan.id
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

    static let empty = OrganizePreviewSnapshot(rows: [], indexesByID: [:], outsideIndexes: [], outsideScope: [], allScope: [], selection: BatchSelection(), droppedSelectionCount: 0)

    static func load(database: LibraryDatabase, musicFolder: URL, template: String,
                     previous: OrganizePreviewSnapshot, selected: BatchSelection,
                     cancellation: OrganizePlanningCancellation) async throws -> OrganizePreviewSnapshot
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
        let plans = try LibraryOrganizer.findMoves(in: files, musicFolder: musicFolder, template: template, checkCancellation: cancellation.check)
        let filesByID = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.id.map { identifier in (identifier, file) } })
        var rows: [Row] = []
        var indexesByID: [Int64: Int] = [:]
        var outsideIndexes: [Int] = []
        var outsideScope = IndexSet()
        for plan in plans {
            try cancellation.check()
            let index = rows.count
            indexesByID[plan.id] = index
            let file = filesByID[plan.id]
            rows.append(Row(plan: plan, artist: file?.artist ?? "", title: file?.title ?? (plan.sourcePath as NSString).lastPathComponent))
            if plan.isOutsideMusicFolder {
                outsideIndexes.append(index)
                outsideScope.insert(index)
            }
        }
        var reconciled = BatchSelection()
        for oldIndex in selected.indexes {
            try cancellation.check()
            let oldPlan = previous.rows[oldIndex].plan
            if let index = indexesByID[oldPlan.id], rows[index].plan == oldPlan {
                reconciled.set(true, at: index)
            }
        }
        return OrganizePreviewSnapshot(rows: rows, indexesByID: indexesByID, outsideIndexes: outsideIndexes,
                                       outsideScope: outsideScope, allScope: IndexSet(integersIn: rows.indices),
                                       selection: reconciled, droppedSelectionCount: selected.count - reconciled.count)
    }
}
