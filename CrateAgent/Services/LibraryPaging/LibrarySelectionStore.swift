import Foundation
import GRDB

actor LibrarySelectionStore: PagedSelectionProvider {
    typealias Snapshot = LibraryPagedSnapshot
    typealias Identity = PagedIdentity<Int64>
    /// Reads the scope Select all sets (`selected` true) or clears (false) in id-ordered batches.
    typealias IdentityReader = @Sendable (Snapshot, _ selected: Bool, Int64?, Int) async throws -> [Identity]
    private let pool: DatabasePool
    private var storage: DatabaseQueue?
    private let readIdentities: IdentityReader
    private var epoch: UInt64 = 0

    init(database: LibraryDatabase,
         readIdentities: @escaping IdentityReader = LibrarySelectionStore.scopeIdentities) throws
    {
        guard let pool = database.writer as? DatabasePool else { throw PagingError.unavailableDatabase }
        self.pool = pool
        self.readIdentities = readIdentities
        let storage = try DatabaseQueue(path: "")
        try storage.write { database in
            try database.execute(sql: """
            CREATE TABLE selected_identity (
                id INTEGER PRIMARY KEY, revision INTEGER NOT NULL,
                included INTEGER NOT NULL, capture TEXT
            );
            CREATE TABLE staged_identity (
                operation TEXT NOT NULL, id INTEGER NOT NULL, revision INTEGER NOT NULL,
                PRIMARY KEY (operation, id)
            );
            """)
        }
        self.storage = storage
    }

    func set(_ identities: [Identity], selected: Bool) throws {
        try Task.checkCancellation()
        try requireStorage().write { database in
            for identity in identities {
                if selected {
                    try database.execute(sql: """
                    INSERT INTO selected_identity(id, revision, included) VALUES (?, ?, 1)
                    ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, included = 1
                    """, arguments: [identity.id, identity.revision])
                } else {
                    try database.execute(sql: "UPDATE selected_identity SET included = 0 WHERE id = ? AND revision = ?", arguments: [identity.id, identity.revision])
                }
            }
        }
    }

    /// Select all takes main and standalone rows (plus eligible alternates when
    /// included); clearing it takes every in-scope file, so it also removes
    /// alternates that Include alternates or a family checkbox added.
    static let scopeIdentities: IdentityReader = { snapshot, selected, after, limit in
        selected ? try await snapshot.selectAllIdentities(after: after, limit: limit) : try await snapshot.identities(after: after, limit: limit)
    }

    func setScope(_ snapshot: Snapshot, selected: Bool) async throws {
        var lastID: Int64?
        try await capture(selected: selected) { [readIdentities] in
            let batch = try await readIdentities(snapshot, selected, lastID, 200)
            lastID = batch.last?.id
            return batch
        }
    }

    func setRange(_ range: Range<Int>, in snapshot: Snapshot, selected: Bool) async throws {
        let count = await snapshot.count()
        guard range.lowerBound >= 0, range.upperBound <= count else { throw PagingError.invalidRange }
        var offset = range.lowerBound
        try await capture(selected: selected) {
            guard offset < range.upperBound else { return [] }
            let end = min(range.upperBound, offset + 200)
            let batch = try await snapshot.identities(in: offset ..< end)
            offset = end
            return batch
        }
    }

    func selectedIDs(in identities: [Identity]) throws -> Set<Int64> {
        try Task.checkCancellation()
        guard !identities.isEmpty else { return [] }
        return try requireStorage().read { database in
            let arguments = StatementArguments(identities.map(\.id))
            let placeholders = Array(repeating: "?", count: identities.count).joined(separator: ",")
            let expected = Set(identities)
            let rows = try Row.fetchAll(database, sql: "SELECT id, revision FROM selected_identity WHERE included = 1 AND id IN (\(placeholders))", arguments: arguments)
            return Set(rows.compactMap { row in
                let identity = Identity(id: row["id"], revision: row["revision"])
                return expected.contains(identity) ? identity.id : nil
            })
        }
    }

    /// Selected files the snapshot still shows, collapsed alternates included,
    /// at the revision they were selected at. Throws when more than `limit`,
    /// or when a selected file changed after it was selected, naming it, so a
    /// command never acts on part of what the user chose.
    func selectedIdentities(in snapshot: Snapshot, limit: Int) async throws -> [Identity] {
        var selected: [Identity] = []
        var changed: [Int64] = []
        var lastID: Int64?
        while true {
            try Task.checkCancellation()
            let batch = try await snapshot.identities(after: lastID, limit: 200)
            guard let last = batch.last else { break }
            let revisions = try selectedRevisions(of: batch)
            for identity in batch {
                guard let revision = revisions[identity.id] else { continue }
                if revision == identity.revision {
                    selected.append(identity)
                } else {
                    changed.append(identity.id)
                }
            }
            guard selected.count + changed.count <= limit else { throw LibrarySelectionError.tooManySelected(limit: limit) }
            lastID = last.id
        }
        guard changed.isEmpty else {
            let names = try await pool.read { database in try FileRecord.filter(keys: changed).order(Column("id")).fetchAll(database).map(\.displayName) }
            throw LibrarySelectionError.changedSinceSelected(files: names)
        }
        return selected
    }

    private func selectedRevisions(of identities: [Identity]) throws -> [Int64: Int64] {
        let placeholders = Array(repeating: "?", count: identities.count).joined(separator: ",")
        return try requireStorage().read { database in
            try Row.fetchAll(database, sql: "SELECT id, revision FROM selected_identity WHERE included = 1 AND id IN (\(placeholders))",
                             arguments: StatementArguments(identities.map(\.id)))
                .reduce(into: [Int64: Int64]()) { revisions, row in revisions[row["id"]] = row["revision"] }
        }
    }

    func summary(in snapshot: Snapshot) async throws -> PagedSelectionSummary {
        let requestedEpoch = epoch
        let total = try await requireStorage().read { database in
            guard let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM selected_identity WHERE included = 1") else { throw PagingError.incompletePage }
            return count
        }
        let scopeCount = await snapshot.selectAllCount()
        guard total > 0 else { return .init(total: 0, inScope: 0, scopeCount: scopeCount, removed: 0, scopeSelected: 0) }
        let inScope = try await countSelected { after in try await snapshot.identities(after: after, limit: 200) }
        let scopeSelected = try await countSelected { after in try await snapshot.selectAllIdentities(after: after, limit: 200) }
        guard requestedEpoch == epoch else { throw CancellationError() }
        return .init(total: total, inScope: inScope, scopeCount: scopeCount, removed: 0, scopeSelected: scopeSelected)
    }

    /// Selected identities across a scope read in id-ordered batches.
    private func countSelected(batch nextBatch: (Int64?) async throws -> [Identity]) async throws -> Int {
        let requestedEpoch = epoch
        var selected = 0
        var lastID: Int64?
        while true {
            try Task.checkCancellation()
            let batch = try await nextBatch(lastID)
            guard requestedEpoch == epoch else { throw CancellationError() }
            if batch.isEmpty {
                break
            }
            selected += try selectedIDs(in: batch).count
            lastID = batch.last?.id
        }
        return selected
    }

    func reconcile() throws -> Int {
        try Task.checkCancellation()
        let storage = try requireStorage()
        let reader = try pool.makeSnapshot()
        return try storage.write { database in
            var lastID: Int64?
            var removed = 0
            while true {
                try Task.checkCancellation()
                let predicate = lastID == nil ? "" : " AND id > ?"
                let arguments: StatementArguments = lastID.map { identifier in [identifier] } ?? []
                let batch = try Row.fetchAll(database, sql: "SELECT id, revision FROM selected_identity WHERE included = 1\(predicate) ORDER BY id LIMIT 200", arguments: arguments)
                    .map { row in Identity(id: row["id"], revision: row["revision"]) }
                if batch.isEmpty {
                    break
                }
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let current = try reader.read { library in
                    try Set(Row.fetchAll(library, sql: "SELECT id, membership_revision FROM files WHERE id IN (\(placeholders))", arguments: StatementArguments(batch.map(\.id)))
                        .map { row in Identity(id: row["id"], revision: row["membership_revision"]) })
                }
                for identity in batch where !current.contains(identity) {
                    try database.execute(sql: "DELETE FROM selected_identity WHERE id = ?", arguments: [identity.id])
                    removed += 1
                }
                lastID = batch.last?.id
            }
            return removed
        }
    }

    func clear() throws {
        epoch &+= 1
        try requireStorage().write { database in
            try database.execute(sql: "DELETE FROM selected_identity; DELETE FROM staged_identity")
        }
    }

    func close() {
        epoch &+= 1
        storage = nil
    }

    private func requireStorage() throws -> DatabaseQueue {
        guard let storage else { throw CancellationError() }
        return storage
    }

    private func capture(selected: Bool, nextBatch: () async throws -> [Identity]) async throws {
        let requestedEpoch = epoch
        let operation = UUID().uuidString
        let storage = try requireStorage()
        do {
            while true {
                try Task.checkCancellation()
                let batch = try await nextBatch()
                guard requestedEpoch == epoch else { throw CancellationError() }
                if batch.isEmpty {
                    break
                }
                try await storage.write { database in
                    for identity in batch {
                        try database.execute(sql: "INSERT INTO staged_identity(operation, id, revision) VALUES (?, ?, ?)", arguments: [operation, identity.id, identity.revision])
                    }
                }
            }
            try Task.checkCancellation()
            guard requestedEpoch == epoch else { throw CancellationError() }
            try await storage.write { database in
                if selected {
                    try database.execute(sql: """
                    INSERT INTO selected_identity(id, revision, included, capture)
                    SELECT id, revision, 1, operation FROM staged_identity WHERE operation = ?
                    ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, included = 1, capture = excluded.capture
                    """, arguments: [operation])
                } else {
                    try database.execute(sql: """
                    UPDATE selected_identity SET included = 0 WHERE EXISTS (
                        SELECT 1 FROM staged_identity WHERE operation = ?
                        AND staged_identity.id = selected_identity.id AND staged_identity.revision = selected_identity.revision
                    )
                    """, arguments: [operation])
                }
                try database.execute(sql: "DELETE FROM staged_identity WHERE operation = ?", arguments: [operation])
            }
        } catch {
            try await storage.write { database in
                try database.execute(sql: "DELETE FROM staged_identity WHERE operation = ?", arguments: [operation])
            }
            throw error
        }
    }
}

enum LibrarySelectionError: LocalizedError, Equatable {
    case tooManySelected(limit: Int)
    case changedSinceSelected(files: [String])

    var errorDescription: String? {
        switch self {
        case let .tooManySelected(limit): "Select at most \(limit) files for this action."
        case let .changedSinceSelected(files):
            "\(files.map { file in "“\(file)”" }.formatted(.list(type: .and))) changed after you selected \(files.count == 1 ? "it" : "them"). Select \(files.count == 1 ? "it" : "them") again, then retry."
        }
    }
}
