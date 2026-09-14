import SwiftUI

/// One row in the Auto-Tag panel's selection-stage search results.
///
/// Plain value-type row, manually `Equatable` over everything it
/// displays (`onToggle` is a closure and deliberately excluded from
/// the comparison — closures aren't `Equatable`, and it never affects
/// what the row renders). Used with `.equatable()` at the call site
/// so SwiftUI can skip re-diffing a row's body when none of its
/// fields changed — toggling one row's selection no longer forces
/// every visible row to re-render, mirroring the row-diff-avoidance
/// pattern `LibraryHygieneView`'s Duplicates panel uses for its
/// keeper cache.
struct AutoTagSelectionRow: View, Equatable {
    let fileID: Int64
    let path: String
    let artist: String?
    let title: String?
    let isSelected: Bool
    let onToggle: () -> Void

    static func == (lhs: AutoTagSelectionRow, rhs: AutoTagSelectionRow) -> Bool {
        lhs.fileID == rhs.fileID
            && lhs.path == rhs.path
            && lhs.artist == rhs.artist
            && lhs.title == rhs.title
            && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                Text((path as NSString).lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private var displayTitle: String {
        switch (artist, title) {
        case let (artist?, title?): return "\(artist) — \(title)"
        case let (artist?, nil): return artist
        case let (nil, title?): return title
        case (nil, nil): return (path as NSString).lastPathComponent
        }
    }
}
