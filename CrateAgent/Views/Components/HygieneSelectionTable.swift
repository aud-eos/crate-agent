import SwiftUI

struct HygieneSelectionTable<Row: Identifiable & Equatable>: View {
    @Binding var results: ListResultSelection<Row>
    let identities: [String: TrackDisplayIdentity]
    let enabled: Bool
    var contentRevision = ""
    var blockReason: (Row) -> String? = { _ in nil }
    let path: (Row) -> String
    let field: (Row) -> String
    let oldValue: (Row) -> String
    let newValue: (Row) -> String
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        let rows = results.visibleRows
        VirtualizedPreviewTable(
            dataID: "\(results.generation):\(contentRevision)", accessibilityLabel: "Cleanup preview", rowCount: rows.count,
            row: { index in rows[index] }, columns: [
                PreviewTableColumn(identifier: "artist", title: "Artist", width: 150, text: { row in identities[path(row)]?.artist ?? "" }),
                PreviewTableColumn(identifier: "title", title: "Title", width: 200, text: { row in identities[path(row)]?.title ?? (path(row) as NSString).lastPathComponent }),
                PreviewTableColumn(identifier: "field", title: "Field", width: 90, text: field),
                PreviewTableColumn(identifier: "current", title: "Current", width: 180, text: oldValue),
                PreviewTableColumn(identifier: "proposed", title: "Proposed", width: 180, text: newValue),
                PreviewTableColumn(identifier: "status", title: "Status", width: 280, text: { row in blockReason(row) ?? "Ready" }),
                PreviewTableColumn(identifier: "path", title: "Path", width: 260, text: path),
            ], selection: .init(
                accessibilityName: { row in "\(field(row)) for \(path(row))" },
                isSelected: { identifier in results.selectedIDs.contains(identifier) }, setSelected: { identifier, selected in results.setSelected(selected, id: identifier) },
                selectAll: { results.selectVisible(true) }, isSelectable: { row in blockReason(row) == nil }
            ), enabled: enabled, density: density, sort: { column, ascending in
                results.sort(column: column, ascending: ascending) { first, second in
                    let order = sortText(first, column: column).localizedStandardCompare(sortText(second, column: column))
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
            }
        )
    }

    private func sortText(_ row: Row, column: String) -> String {
        switch column {
        case "artist": identities[path(row)]?.artist ?? ""
        case "title": identities[path(row)]?.title ?? (path(row) as NSString).lastPathComponent
        case "field": field(row)
        case "current": oldValue(row)
        case "proposed": newValue(row)
        case "path": path(row)
        case "status": blockReason(row) ?? "Ready"
        default: preconditionFailure("Unknown Cleanup column")
        }
    }
}
