import Foundation

/// View-layer convenience properties on `FileRecord`. Kept separate
/// from the model definition so the core record stays focused on its
/// persistence shape. These are computed properties — they aren't
/// serialized to/from the database.
extension FileRecord {

    /// Final path component, e.g. "Track Name.mp3". Used as the
    /// primary identifier shown in the library browser table.
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
}
