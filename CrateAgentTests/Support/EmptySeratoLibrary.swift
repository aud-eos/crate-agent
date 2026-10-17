@testable import CrateAgent
import Foundation
import XCTest

extension XCTestCase {
    /// A real Serato library folder whose `database V2` holds no tracks, for
    /// engines whose tests are not about Serato. Their Serato writes run the
    /// real path and find no record, instead of waiting for a library that
    /// does not exist (#192). Removed when the test ends.
    func makeEmptySeratoLibrary() throws -> SeratoLibraryLocator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmptySerato-\(UUID().uuidString)", isDirectory: true)
        let locator = SeratoLibraryLocator(seratoDirectory: directory)
        try FileManager.default.createDirectory(at: locator.subcratesDirectoryUrl, withIntermediateDirectories: true)
        try SeratoTestEncoding.library(paths: []).write(to: locator.databaseV2Url)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return locator
    }
}
