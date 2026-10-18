@testable import CrateAgent

/// Keeper and resolver tests build groups from plain `files` rows, which
/// carry no History plays. Production groups are always `DuplicateFileRow`,
/// which loads them, so this conformance exists only in tests.
extension FileRecord: @retroactive DuplicateFileSource {
    public var seratoPlayCount: Int {
        0
    }
}
