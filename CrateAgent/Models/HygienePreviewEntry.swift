import Foundation

protocol HygienePreviewEntry: Identifiable, Equatable {
    var path: String { get }
    var fileId: Int64 { get }
    var field: SeratoMetadataField { get }
    var currentPreview: String { get }
    var proposedPreview: String { get }
}

extension LibraryHygiene.WhitespaceIssue: HygienePreviewEntry {
    var currentPreview: String {
        WhitespacePreview(current: oldValue, proposed: newValue).visibleCurrent
    }

    var proposedPreview: String {
        WhitespacePreview(current: oldValue, proposed: newValue).visibleProposed
    }
}

extension LibraryHygiene.FindAndReplaceMatch: HygienePreviewEntry {
    var currentPreview: String {
        oldValue
    }

    var proposedPreview: String {
        newValue
    }
}

extension LibraryHygiene.MissingFieldEntry: HygienePreviewEntry {
    var currentPreview: String {
        "Not set"
    }

    var proposedPreview: String {
        ""
    }
}
