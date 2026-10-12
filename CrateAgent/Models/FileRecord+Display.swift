import Foundation

/// View-layer convenience properties on `FileRecord`. Kept separate
/// from the model definition so the core record stays focused on its
/// persistence shape. These are computed properties — they aren't
/// serialized to/from the database.
public extension FileRecord {
    /// Final path component, e.g. "Track Name.mp3". Used as the
    /// fallback display when no `title` metadata is present.
    var filenameOnly: String {
        (path as NSString).lastPathComponent
    }

    /// Directory portion of the path. Useful as a secondary sort key
    /// or display column.
    var folderPath: String {
        (path as NSString).deletingLastPathComponent
    }

    /// Raw-value string of `fingerprintStatus`. SwiftUI's
    /// KeyPathComparator works with Comparable values; raw strings
    /// sort lexicographically, which is fine for our three-state enum.
    var fingerprintStatusRawValue: String {
        fingerprintStatus.rawValue
    }

    /// SwiftUI's TableColumn sort keypaths require a Comparable value.
    /// Optional Strings are NOT Comparable (Optional gets Equatable
    /// and Hashable but not Comparable), so the table sort comparators
    /// can't take `\.artist` directly. These projections return "" for
    /// nil so nil sorts first alphabetically — matches user
    /// expectations for sparse columns.
    var artistOrEmpty: String {
        artist ?? ""
    }

    var titleOrEmpty: String {
        title ?? ""
    }

    var albumOrEmpty: String {
        album ?? ""
    }

    var genreOrEmpty: String {
        genre ?? ""
    }

    var bpmOrEmpty: String {
        bpm ?? ""
    }

    var musicalKeyOrEmpty: String {
        musicalKey ?? ""
    }
}
