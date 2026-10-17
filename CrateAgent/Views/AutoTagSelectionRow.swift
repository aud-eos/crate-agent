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
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let fileID: Int64
    let path: String
    let artist: String?
    let title: String?
    var libraryMembership: LibraryMembership = .legacyUnverified
    var fileAvailability: FileAvailability = .unknown
    var processingBlockReason: String?
    let isSelected: Bool
    let onToggle: () -> Void

    static func == (lhs: AutoTagSelectionRow, rhs: AutoTagSelectionRow) -> Bool {
        lhs.fileID == rhs.fileID
            && lhs.path == rhs.path
            && lhs.artist == rhs.artist
            && lhs.title == rhs.title
            && lhs.libraryMembership == rhs.libraryMembership
            && lhs.fileAvailability == rhs.fileAvailability
            && lhs.processingBlockReason == rhs.processingBlockReason
            && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(alignment: .top, spacing: density.detailSpacing) {
            Toggle("Select \(displayTitle)", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!file.canProcess)
                .accessibilityLabel("Select \(displayTitle)")
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                TrackHeading(artist: artist, title: title, filename: (path as NSString).lastPathComponent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(path)
                LibraryFileStatusView(file: file)
            }
        }
        .padding(.vertical, density.rowPadding)
    }

    private var file: BrowserRow {
        var row = BrowserRow(id: fileID, path: path, artist: artist, title: title, libraryMembership: libraryMembership, fileAvailability: fileAvailability)
        row.processingBlockReason = processingBlockReason
        return row
    }

    private var displayTitle: String {
        switch (artist, title) {
        case let (artist?, title?): "\(artist) — \(title)"
        case let (artist?, nil): artist
        case let (nil, title?): title
        case (nil, nil): (path as NSString).lastPathComponent
        }
    }
}
