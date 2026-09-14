@testable import CrateAgent
import GRDB

@MainActor
final class ProcessingTestSeratoState {
    var isRunning: Bool
    var watchdog: SeratoWatchdog?

    init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    func stop() {
        isRunning = false
        watchdog?.refresh()
    }
}

func markProcessingFixturesAvailable(in database: LibraryDatabase, membership: LibraryMembership = .active) async throws {
    try await database.writer.write { connection in
        try connection.execute(sql: "UPDATE files SET library_membership = ?, file_availability = ?",
                               arguments: [membership.rawValue, FileAvailability.available.rawValue])
    }
}
