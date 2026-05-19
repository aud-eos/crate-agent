import Foundation

/// View-layer convenience properties on `FileRecord`. Kept separate
/// from the model definition so the core record stays focused on its
/// persistence shape. These are computed properties — they aren't
/// serialized to/from the database.
extension FileRecord {

    /// Final path component, e.g. "Track Name.mp3". Used as the
    /// fallback display when no `title` metadata is present.
    public var filenameOnly: String {
        (path as NSString).lastPathComponent
    }

    /// Directory portion of the path. Useful as a secondary sort key
    /// or display column.
    public var folderPath: String {
        (path as NSString).deletingLastPathComponent
    }

    /// Raw-value string of `fingerprintStatus`. SwiftUI's
    /// KeyPathComparator works with Comparable values; raw strings
    /// sort lexicographically, which is fine for our three-state enum.
    public var fingerprintStatusRawValue: String {
        fingerprintStatus.rawValue
    }

    // SwiftUI's TableColumn sort keypaths require a Comparable value.
    // Optional Strings are NOT Comparable (Optional gets Equatable
    // and Hashable but not Comparable), so the table sort comparators
    // can't take `\.artist` directly. These projections return "" for
    // nil so nil sorts first alphabetically — matches user
    // expectations for sparse columns.
    public var artistOrEmpty: String { artist ?? "" }
    public var titleOrEmpty: String { title ?? "" }
    public var albumOrEmpty: String { album ?? "" }
    public var genreOrEmpty: String { genre ?? "" }
    public var bpmOrEmpty: String { bpm ?? "" }
    public var musicalKeyOrEmpty: String { musicalKey ?? "" }
}
