import Combine
import Foundation

@MainActor
final class OrganizePreviewModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case outsideOnly, all
        var id: String {
            rawValue
        }

        var displayName: String {
            self == .outsideOnly ? "Outside music folder" : "All"
        }
    }

    @Published private(set) var snapshot = OrganizePreviewSnapshot.empty
    @Published private(set) var selection = BatchSelection()
    @Published private(set) var filter: Filter = .outsideOnly
    @Published private(set) var isScanning = false
    @Published private(set) var isApplying = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?

    @Published private(set) var query = ""
    @Published private(set) var visibleIndexes: [Int] = []
    private var sortColumn = ""
    private var sortAscending = true
    private var filteredScope = IndexSet()

    func setQuery(_ query: String) {
        guard !isBusy else { return }
        self.query = query
        refilter()
    }

    func sort(column: String, ascending: Bool) {
        guard !isBusy else { return }
        sortColumn = column
        sortAscending = ascending
        refilter()
    }

    private func sortText(_ row: OrganizePreviewSnapshot.Row) -> String {
        switch sortColumn {
        case "artist": row.artist
        case "title": row.title
        case "status": row.status
        case "source": row.sourcePath
        case "destination": row.plan?.destinationPath ?? ""
        case "location": row.isOutsideMusicFolder ? "Outside music folder" : "Inside music folder"
        default: preconditionFailure("Unknown Organize column")
        }
    }

    @Published private(set) var displayGeneration = UUID()

    private func refilter() {
        let needle = ListSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let candidates = filter == .all ? Array(snapshot.rows.indices) : snapshot.outsideIndexes
        visibleIndexes = needle.isEmpty ? candidates : candidates.filter { index in snapshot.rows[index].searchText.contains(needle) }
        if !sortColumn.isEmpty {
            visibleIndexes.sort { first, second in
                let order = sortText(snapshot.rows[first]).localizedStandardCompare(sortText(snapshot.rows[second]))
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        displayGeneration = UUID()
        filteredScope = IndexSet(visibleIndexes).intersection(snapshot.allScope)
    }

    private var requestID = UUID()
    private var worker: Task<OrganizePreviewSnapshot, Error>?
    private var cancellation: OrganizePlanningCancellation?

    var isBusy: Bool {
        isScanning || isApplying
    }

    var visibleCount: Int {
        visibleIndexes.count
    }

    var scope: IndexSet {
        filteredScope
    }

    var visibleBlockedCount: Int {
        visibleCount - scope.count
    }

    var hiddenSelectionCount: Int {
        selection.count - selection.count(in: scope)
    }

    func setFilter(_ filter: Filter) {
        guard !isBusy else { return }
        self.filter = filter
        refilter()
    }

    func isSelected(_ identifier: Int64) -> Bool {
        guard let index = snapshot.indexesByID[identifier] else { return false }
        return selection.indexes.contains(index)
    }

    func setSelected(_ selected: Bool, identifier: Int64) {
        guard !isBusy, let index = snapshot.indexesByID[identifier], snapshot.rows[index].plan != nil else { return }
        selection.set(selected, at: index)
    }

    func selectScope(_ selected: Bool) {
        guard !isBusy else { return }
        selection.set(selected, in: scope)
    }

    func clearSelection() {
        guard !isBusy else { return }
        selection.clear()
    }

    func cancelScan() {
        guard isScanning else { return }
        requestID = UUID()
        cancellation?.cancel()
        worker?.cancel()
        worker = nil
        cancellation = nil
        isScanning = false
        notice = OrganizeMessages.scanCancelled
    }

    func rescan(database: LibraryDatabase, musicFolder: URL, template: String, readiness: LibrarySyncReadiness? = nil) async {
        guard !isApplying else { return }
        cancelScan()
        let currentRequest = UUID()
        requestID = currentRequest
        let cancellation = OrganizePlanningCancellation()
        self.cancellation = cancellation
        let previous = snapshot
        let selected = selection
        isScanning = true
        error = nil
        notice = nil
        let worker = Task.detached(priority: .userInitiated) {
            try await OrganizePreviewSnapshot.load(database: database, musicFolder: musicFolder, template: template,
                                                   previous: previous, selected: selected, cancellation: cancellation, readiness: readiness)
        }
        self.worker = worker
        defer {
            if requestID == currentRequest {
                isScanning = false
                self.worker = nil
                self.cancellation = nil
            }
        }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                cancellation.cancel()
                worker.cancel()
            }
            try Task.checkCancellation()
            guard requestID == currentRequest else { return }
            snapshot = loaded
            refilter()
            selection = loaded.selection
            if loaded.droppedSelectionCount > 0 {
                notice = "\(loaded.droppedSelectionCount) selected proposals changed or disappeared and were deselected. Review the updated preview."
            }
        } catch is CancellationError {
            if requestID == currentRequest {
                notice = OrganizeMessages.scanCancelled
            }
        } catch {
            if requestID == currentRequest {
                self.error = "Couldn't scan library: \(error.localizedDescription)"
            }
        }
    }

    func beginApply() async -> [LibraryOrganizer.Plan] {
        guard !isBusy, selection.count > 0 else { return [] }
        isApplying = true
        let snapshot = snapshot
        let selected = selection
        return await Task.detached(priority: .userInitiated) {
            selected.indexes.map { index in
                guard let plan = snapshot.rows[index].plan else { preconditionFailure("Blocked rows cannot be applied") }
                return plan
            }
        }.value
    }

    func finishApply() {
        isApplying = false
    }
}
