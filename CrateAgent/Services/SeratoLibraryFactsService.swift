import Foundation

/// Keeps the Serato fact tables in step with database V2 and Subcrates.
/// Serato's files are read only while Serato is closed, and each source only
/// when its stored stamp differs from its current files and the library's
/// paths, so an unchanged restart reads nothing. A skipped or failed refresh
/// keeps the previous rows and stamps.
@MainActor
final class SeratoLibraryFactsService: ObservableObject {
    enum Status: Equatable {
        case notRefreshed
        case refreshing
        case refreshed(SeratoLibraryFactsSummary)
        case skippedWhileSeratoRunning
        /// The reason the last read failed; the facts shown are older or partial.
        case failed(String)
    }

    typealias FactsReader = @Sendable (_ databasePath: String) async throws -> SeratoTrackFactsScan
    typealias CrateReader = @Sendable (_ cratePath: String) async throws -> [String]

    /// What a source's stamp records: its files, the library's paths, and
    /// which files are retired.
    private struct SourceInputs<Files: Encodable>: Encodable {
        let files: Files
        let library: SeratoLibraryPathSignature
        let lastMembershipChange: Int64?
    }

    @Published private(set) var status: Status = .notRefreshed

    private let database: LibraryDatabase
    private let seratoLocator: SeratoLibraryLocator
    private let watchdog: SeratoWatchdog
    private let readFacts: FactsReader
    private let readCrate: CrateReader
    private var isRefreshing = false
    private var refreshRequested = false

    init(database: LibraryDatabase, seratoLocator: SeratoLibraryLocator, watchdog: SeratoWatchdog,
         readFacts: @escaping FactsReader = { path in try readDatabaseTrackFacts(databasePath: path) },
         readCrate: @escaping CrateReader = { path in try readCratePaths(cratePath: path) })
    {
        self.database = database
        self.seratoLocator = seratoLocator
        self.watchdog = watchdog
        self.readFacts = readFacts
        self.readCrate = readCrate
    }

    /// A request made while a refresh runs is coalesced into one more pass.
    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            await refreshOnce()
        } while refreshRequested
    }

    private func refreshOnce() async {
        let revision = watchdog.stateRevision
        guard watchdog.isClosed(atRevision: revision) else {
            status = .skippedWhileSeratoRunning
            return
        }
        let databaseURL = seratoLocator.databaseV2Url
        let subcratesDirectory = seratoLocator.subcratesDirectoryUrl
        do {
            let (identity, crateFiles) = try await Task.detached {
                try (SeratoSourceIdentity.read(databaseURL), SeratoDirectoryStamp.all(in: subcratesDirectory, pathExtension: SeratoLibraryLocator.crateExtension))
            }.value
            let (library, membershipChange, stored) = try await database.writer.read { connection in
                try (SeratoPlayCounts.librarySignature(in: connection), SeratoLibraryFacts.lastMembershipChange(in: connection),
                     SeratoLibraryFacts.storedStamps(in: connection))
            }
            let stamps = try [
                ChecklistSource.databaseV2: Self.encode(SourceInputs(files: identity, library: library, lastMembershipChange: membershipChange)),
                .subcrates: Self.encode(SourceInputs(files: crateFiles, library: library, lastMembershipChange: membershipChange)),
            ]
            let changed = Set(SeratoLibraryFacts.sources.filter { source in stored[source]?.inputs != stamps[source] })
            guard !changed.isEmpty else {
                status = Self.status(for: stored.values.map(\.outcome).reduce(SeratoLibraryFactsOutcome(), +))
                return
            }
            status = .refreshing
            let readFacts = readFacts
            let readCrate = readCrate
            let (facts, crates) = try await Task.detached {
                let facts = changed.contains(.databaseV2) ? try await readFacts(databaseURL.path) : nil
                var crates: [String: [String]]?
                if changed.contains(.subcrates) {
                    var paths: [String: [String]] = [:]
                    for crate in crateFiles {
                        paths[crate.name] = try await readCrate(subcratesDirectory.appendingPathComponent(crate.name).path)
                    }
                    crates = paths
                }
                return (facts, crates)
            }.value
            guard watchdog.isClosed(atRevision: revision) else {
                status = .skippedWhileSeratoRunning
                return
            }
            let plan = try await database.writer.read { connection in
                try SeratoLibraryFacts.plan(facts: facts, crates: crates, stamps: stamps, in: connection)
            }
            guard try await SeratoLibraryFacts.apply(plan, to: database.writer) else {
                refreshRequested = true
                return
            }
            status = Self.status(for: plan.outcome)
        } catch {
            status = .failed((error as? CoreError)?.message ?? error.localizedDescription)
        }
    }

    private static func status(for outcome: SeratoLibraryFactsOutcome) -> Status {
        outcome.malformedRecordCount > 0
            ? .failed(SeratoLibraryFactsMessages.unreadableRecords(outcome.malformedRecordCount))
            : .refreshed(outcome.summary)
    }

    private static func encode(_ inputs: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(inputs), as: UTF8.self)
    }
}
