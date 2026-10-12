import Foundation

struct ListResultSelection<Row: Identifiable & Equatable> {
    private(set) var rows: [Row] = []
    private(set) var visibleRows: [Row] = []
    private(set) var selectedIDs: Set<Row.ID> = []
    private(set) var query = ""
    private(set) var generation = UUID()
    private(set) var droppedSelectionCount = 0
    private(set) var sortColumn: String?
    private(set) var sortAscending = true
    private var context = ""
    private var searchIndex: [Row.ID: String] = [:]
    private var revisions: [Row.ID: String] = [:]
    private var visibleIDs: Set<Row.ID> = []

    var selectedRows: [Row] {
        rows.filter { row in selectedIDs.contains(row.id) }
    }

    var hiddenSelectionCount: Int {
        selectedIDs.subtracting(visibleIDs).count
    }

    var coverage: BatchSelection.Coverage {
        ListSelectionCoverage.coverage(selected: selectedIDs, scope: visibleIDs)
    }

    mutating func replace(_ rows: [Row], context: String,
                          revision: (Row) -> String = { _ in "" }, searchText: (Row) -> String)
    {
        let previous = Dictionary(uniqueKeysWithValues: self.rows.map { row in (row.id, row) })
        let oldCount = selectedIDs.count
        let newRevisions = Dictionary(uniqueKeysWithValues: rows.map { row in (row.id, revision(row)) })
        if context != self.context {
            selectedIDs = []
            droppedSelectionCount = 0
        } else {
            selectedIDs = Set(rows.compactMap { row in
                selectedIDs.contains(row.id) && previous[row.id] == row && revisions[row.id] == newRevisions[row.id] ? row.id : nil
            })
            droppedSelectionCount = oldCount - selectedIDs.count
        }
        self.context = context
        self.rows = rows
        revisions = newRevisions
        searchIndex = Dictionary(uniqueKeysWithValues: rows.map { row in (row.id, ListSearch.normalized(searchText(row))) })
        refilter()
    }

    mutating func setQuery(_ query: String) {
        self.query = query
        refilter()
    }

    mutating func setSelected(_ selected: Bool, id: Row.ID) {
        guard searchIndex[id] != nil else { return }
        if selected {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
    }

    mutating func selectVisible(_ selected: Bool) {
        if selected {
            selectedIDs.formUnion(visibleIDs)
        } else {
            selectedIDs.subtract(visibleIDs)
        }
    }

    mutating func clearSelection() {
        selectedIDs = []
    }

    mutating func sort(column: String, ascending: Bool, by areInIncreasingOrder: (Row, Row) -> Bool) {
        sortColumn = column
        sortAscending = ascending
        rows.sort(by: areInIncreasingOrder)
        refilter()
    }

    private mutating func refilter() {
        let needle = ListSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        visibleRows = needle.isEmpty ? rows : rows.filter { row in searchIndex[row.id]?.contains(needle) == true }
        visibleIDs = Set(visibleRows.map(\.id))
        generation = UUID()
    }
}

enum ListSelectionCoverage {
    static func coverage<Identifier: Hashable>(selected: Set<Identifier>, scope: Set<Identifier>) -> BatchSelection.Coverage {
        let count = selected.intersection(scope).count
        return count == 0 ? .none : count == scope.count ? .all : .partial
    }
}

extension ListResultSelection where Row: HygienePreviewEntry {
    mutating func replaceHygiene(_ rows: [Row], files: [HygieneFileRow], context: String, proposalRevision: String = "", fileID: (Row) -> Int64) {
        let filesByID = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.id.map { identifier in (identifier, file) } })
        replace(rows, context: context, revision: { row in
            guard let file = filesByID[fileID(row)] else { preconditionFailure("Cleanup result is missing its source file") }
            return "\(file.membershipRevision):\(file.path):\(proposalRevision)"
        }, searchText: { row in
            guard let file = filesByID[fileID(row)] else { preconditionFailure("Cleanup result is missing its source file") }
            return ListSearch.text(artist: file.artist, title: file.title, album: file.album, path: file.path)
        })
        if let column = sortColumn {
            let ascending = sortAscending
            func value(_ row: Row) -> String {
                switch column {
                case "artist": filesByID[fileID(row)]?.artist ?? ""
                case "title": filesByID[fileID(row)]?.title ?? (row.path as NSString).lastPathComponent
                case "field": row.field.displayName
                case "current": row.currentPreview
                case "proposed": row is LibraryHygiene.MissingFieldEntry ? proposalRevision : row.proposedPreview
                case "path": row.path
                default: preconditionFailure("Unknown Cleanup column")
                }
            }
            sort(column: column, ascending: ascending) { first, second in
                let order = value(first).localizedStandardCompare(value(second))
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
    }
}
