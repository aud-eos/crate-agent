import Combine
import Foundation
import GRDB

enum AutoTagReviewMode: String, CaseIterable, Identifiable {
    case list, focus
    var id: String {
        rawValue
    }

    var title: String {
        rawValue.capitalized
    }
}

enum AutoTagSelectionMode: String, CaseIterable, Identifiable {
    case browse, search
    var id: String {
        rawValue
    }

    var title: String {
        self == .browse ? "Browse untagged" : "Search"
    }
}

@MainActor
final class AutoTagSession: ObservableObject {
    nonisolated static func shouldPublishSearchResult(queryTaskRanFor: String, currentQuery: String, isCancelled: Bool) -> Bool {
        !isCancelled && queryTaskRanFor == currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let lookupService: AutoTaggerService
    static let reviewModePreference = "autoTag.reviewMode"
    @Published var reviewMode: AutoTagReviewMode = .list {
        didSet {
            preferences?.set(reviewMode.rawValue, forKey: Self.reviewModePreference)
            if reviewMode == .focus {
                establishFocus()
            }
        }
    }

    @Published var selectionMode: AutoTagSelectionMode = .browse
    @Published private(set) var filesByID: [Int64: BrowserRow] = [:]
    @Published private(set) var rows: [Int64: AutoTaggerService.RowState] = [:]
    @Published private(set) var rowModels: [Int64: AutoTagRowModel] = [:]
    @Published private(set) var selectedFileIDs: Set<Int64> = []
    @Published private(set) var scannedFileIDs: [Int64] = []
    @Published private(set) var confirmedFileIDs: Set<Int64> = []
    @Published private(set) var appliedFileIDs: Set<Int64> = []
    @Published private(set) var searchState = AutoTagSearchState()
    @Published private(set) var browseResults = AutoTagFileBrowse.Results.empty
    @Published private(set) var browseQuery = ""
    @Published private(set) var selectionNotice: String?
    @Published private(set) var browseFilter = AutoTagBrowseFilter.either
    @Published private(set) var isBrowsing = false
    @Published private(set) var browseError: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isApplying = false
    @Published private(set) var actionError: String?
    @Published private(set) var lastResult: String?
    @Published private(set) var haltReason: String?
    @Published private(set) var pendingResyncBatchId: String?
    @Published private(set) var focusedFileID: Int64?
    @Published private(set) var focusNotice: String?
    @Published private(set) var pendingRecordingFileIDs: Set<Int64> = []
    @Published private(set) var selectionErrorByFileID: [Int64: String] = [:]

    var browsePage: Int {
        browseResults.page
    }

    var totalCount: Int {
        scannedFileIDs.count
    }

    var completedCount: Int {
        rows.values.filter {
            state in if case .pending = state {
                return false
            }; return true
        }.count
    }

    var requiresDiscardConfirmation: Bool {
        !scannedFileIDs.isEmpty || isScanning
    }

    private let database: LibraryDatabase
    private let applyBatch: @Sendable ([TrackMutation], String, [Int64: FileMembershipToken]) async throws -> Void
    private let resyncBatch: @Sendable (String) async throws -> ResyncOutcome
    private let preferences: UserDefaults?
    private var subscriptions: Set<AnyCancellable> = []
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var recordingTasks: [Int64: Task<Void, Never>] = [:]
    private var recordingRequests: [Int64: UUID] = [:]
    private var browseTask: Task<Void, Never>?
    private var browseGeneration = 0
    private var browseLoaded = false
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var selectedSnapshots: [Int64: BrowserRow] = [:]
    private var hasFocusedEntry = false
    private var membershipObservation: Task<Void, Never>?
    private var membershipFiles: [Int64: FileRecord] = [:]
    @Published private(set) var processingErrorByFileID: [Int64: String] = [:]

    init(database: LibraryDatabase, lookupService: AutoTaggerService,
         applyBatch: @escaping @Sendable ([TrackMutation], String, [Int64: FileMembershipToken]) async throws -> Void,
         resyncBatch: @escaping @Sendable (String) async throws -> ResyncOutcome,
         preferences: UserDefaults? = .standard)
    {
        self.lookupService = lookupService
        self.database = database
        self.applyBatch = applyBatch
        self.resyncBatch = resyncBatch
        self.preferences = preferences
        if let saved = preferences?.string(forKey: Self.reviewModePreference), let mode = AutoTagReviewMode(rawValue: saved) {
            reviewMode = mode
        }
        lookupService.$rows.sink { [weak self] publishedRows in self?.receive(publishedRows) }.store(in: &subscriptions)
        lookupService.$haltReason.sink { [weak self] error in self?.haltReason = error }.store(in: &subscriptions)
        lookupService.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    private func receive(_ publishedRows: [Int64: AutoTaggerService.RowState]) {
        let scannedIDs = Set(scannedFileIDs)
        rows = publishedRows.filter { scannedIDs.contains($0.key) }
        for fileID in scannedFileIDs where rowModels[fileID] == nil {
            switch rows[fileID] {
            case let .strong(candidate), let .weak(candidate): rowModels[fileID] = AutoTagRowModel(candidate: candidate)
            default: break
            }
        }
        updateProcessingErrors()
        if focusedFileID == nil {
            focusedFileID = scannedFileIDs.first
        }
    }

    private func refreshMembership() throws {
        let fileIDs = scannedFileIDs
        let files = try database.writer.read { database in
            try FileRecord.filter(keys: fileIDs).fetchAll(database)
        }
        membershipFiles = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.id.map { ($0, file) } })
        updateProcessingErrors()
    }

    private func updateProcessingErrors() {
        let tokens = lookupService.membershipTokens(for: scannedFileIDs)
        var reasons: [Int64: String] = [:]
        for fileID in scannedFileIDs {
            do {
                guard let file = membershipFiles[fileID] else { throw FileProcessingEligibilityError.superseded(fileId: fileID) }
                try FileProcessingEligibility.requireProcessable(file)
                if let token = tokens[fileID], token.revision != file.membershipRevision {
                    throw FileProcessingEligibilityError.superseded(fileId: fileID)
                }
            } catch { reasons[fileID] = error.localizedDescription }
        }
        processingErrorByFileID = reasons
        confirmedFileIDs.subtract(reasons.keys)
    }

    private func observeMembership(fileIDs: [Int64]) {
        membershipObservation?.cancel()
        let database = database
        membershipObservation = Task { [weak self] in
            do {
                let observation = ValueObservation.tracking { database in
                    try FileRecord.filter(keys: fileIDs).fetchAll(database)
                }
                for try await files in observation.values(in: database.writer) {
                    guard !Task.isCancelled, let self else { return }
                    membershipFiles = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.id.map { ($0, file) } })
                    updateProcessingErrors()
                }
            } catch { self?.actionError = "Could not verify library membership: \(error.localizedDescription)" }
        }
    }

    func startScan() async {
        guard !isApplying, !isScanning, pendingResyncBatchId == nil, !selectedFileIDs.isEmpty else { return }
        do { try reconcileSelection() } catch {
            actionError = "Could not verify selection: \(error.localizedDescription)"
            return
        }
        guard !selectedFileIDs.isEmpty else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let fileIDs = selectedFileIDs.sorted()
        cancelRecordingRequests()
        rows = [:]
        rowModels = [:]
        scannedFileIDs = []
        confirmedFileIDs = []
        appliedFileIDs = []
        focusedFileID = nil
        hasFocusedEntry = false
        focusNotice = nil
        actionError = nil
        lastResult = nil
        haltReason = nil
        isScanning = true
        let task = Task { [self] in
            do {
                let files = try await database.writer.read { database in
                    try BrowserRow.fetchAll(database, sql: BrowserRow.browserFetchSQL + " WHERE id IN (" + fileIDs.map { _ in "?" }.joined(separator: ",") + ")", arguments: StatementArguments(fileIDs))
                }
                guard generation == scanGeneration, !Task.isCancelled else { return }
                filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
                scannedFileIDs = fileIDs
                focusedFileID = fileIDs.first
                if reviewMode == .focus {
                    establishFocus()
                }
                observeMembership(fileIDs: fileIDs)
                await lookupService.run(fileIDs: fileIDs)
                try refreshMembership()
            } catch {
                guard generation == scanGeneration else { return }
                actionError = "Could not load the selected files: \(error.localizedDescription)"
            }
            guard generation == scanGeneration else { return }
            isScanning = false
            scanTask = nil
        }
        scanTask = task
        await task.value
    }

    func stopScan() {
        guard !isApplying else { return }
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        cancelRecordingRequests()
        lookupService.cancel()
        isScanning = false
    }

    @discardableResult func reset() -> Bool {
        guard !isApplying, pendingResyncBatchId == nil else { return false }
        stopScan()
        membershipObservation?.cancel()
        membershipObservation = nil
        membershipFiles = [:]
        processingErrorByFileID = [:]
        browseGeneration += 1
        browseTask?.cancel()
        browseTask = nil
        browseLoaded = false
        browseResults = .empty
        browseQuery = ""
        selectionNotice = nil
        isBrowsing = false
        browseError = nil
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        searchState = AutoTagSearchState()
        scannedFileIDs = []
        lookupService.reset()
        rows = [:]
        rowModels = [:]
        selectedFileIDs = []
        selectedSnapshots = [:]
        confirmedFileIDs = []
        appliedFileIDs = []
        filesByID = [:]
        focusedFileID = nil
        hasFocusedEntry = false
        focusNotice = nil
        actionError = nil
        lastResult = nil
        selectionErrorByFileID = [:]
        return true
    }

    func selectVisibleFileIDs(_ fileIDs: [Int64]) {
        setVisibleFileIDs(fileIDs, selected: true)
    }

    func setVisibleFileIDs(_ fileIDs: [Int64], selected: Bool) {
        guard !isScanning, !isApplying, scannedFileIDs.isEmpty else { return }
        if selected {
            do {
                let visible = selectionMode == .browse ? browseResults.matches : searchState.results.matches
                let displayed = Dictionary(uniqueKeysWithValues: visible.map { file in (file.id, file) })
                let newIDs = Set(fileIDs).subtracting(selectedFileIDs)
                let missingIDs = newIDs.subtracting(displayed.keys)
                let loaded = try selectionRows(missingIDs)
                let available = displayed.merging(Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) }), uniquingKeysWith: { current, _ in current })
                for identifier in newIDs {
                    guard let file = available[identifier], file.canProcess else { continue }
                    selectedSnapshots[identifier] = file
                    selectedFileIDs.insert(identifier)
                }
            } catch { actionError = "Could not select files: \(error.localizedDescription)" }
        } else {
            selectedFileIDs.subtract(fileIDs)
            for identifier in fileIDs {
                selectedSnapshots[identifier] = nil
            }
        }
    }

    private func selectionRows(_ identifiers: Set<Int64>) throws -> [BrowserRow] {
        guard !identifiers.isEmpty else { return [] }
        return try database.writer.read { connection in
            try BrowserRow.fetchAll(connection, sql: BrowserRow.browserFetchSQL + " WHERE id IN (" + identifiers.map { _ in "?" }.joined(separator: ",") + ")", arguments: StatementArguments(identifiers))
        }
    }

    private func reconcileSelection() throws {
        guard !selectedFileIDs.isEmpty, !isScanning, !isApplying else { return }
        let current = try selectionRows(selectedFileIDs)
        let retained = Set(current.filter { file in file.canProcess && selectedSnapshots[file.id] == file }.map(\.id))
        let removed = selectedFileIDs.subtracting(retained)
        setVisibleFileIDs(Array(removed), selected: false)
        if !removed.isEmpty {
            selectionNotice = "\(removed.count) selected files changed or became unavailable and were deselected."
        }
    }

    func toggleSelection(_ fileID: Int64) {
        setVisibleFileIDs([fileID], selected: !selectedFileIDs.contains(fileID))
    }

    func clearSelection() {
        guard !isScanning, !isApplying, scannedFileIDs.isEmpty else { return }
        selectedFileIDs = []
        selectedSnapshots = [:]
        selectionNotice = nil
    }

    func updateReviewModel(_ model: AutoTagRowModel, for fileID: Int64) {
        guard canApprove(fileID: fileID), let previous = rowModels[fileID],
              model.candidate.fileID == fileID, model.candidate.recordingMBID == previous.candidate.recordingMBID else { return }
        let changed = model.candidate != previous.candidate || model.includeArtist != previous.includeArtist
            || model.includeAlbum != previous.includeAlbum || model.includeYear != previous.includeYear
            || model.titleChoice != previous.titleChoice || model.didUserOverrideAlbum != previous.didUserOverrideAlbum
        rowModels[fileID] = model
        if changed {
            confirmedFileIDs.remove(fileID)
        }
    }

    func setApproved(_ approved: Bool, for fileID: Int64) {
        do { try refreshMembership() } catch { actionError = error.localizedDescription; return }
        guard canApprove(fileID: fileID) else { return }
        if approved {
            confirmedFileIDs.insert(fileID)
        } else {
            confirmedFileIDs.remove(fileID)
        }
    }

    func canApprove(fileID: Int64) -> Bool {
        !isApplying && processingErrorByFileID[fileID] == nil && membershipFiles[fileID] != nil && !appliedFileIDs.contains(fileID) && !pendingRecordingFileIDs.contains(fileID) && rowModels[fileID] != nil
    }

    func approveAllSuggested() {
        do { try refreshMembership() } catch { actionError = error.localizedDescription; return }
        for fileID in scannedFileIDs where canApprove(fileID: fileID) && matchAssessment(for: fileID)?.isBulkApprovalEligible == true {
            confirmedFileIDs.insert(fileID)
        }
    }

    /// Approves every reviewable row except artist/title search matches,
    /// which carry no audio evidence and must be approved one by one.
    func approveAllReady() {
        for fileID in scannedFileIDs where rowModels[fileID]?.candidate.evidence.isMetadataSearch == false {
            setApproved(true, for: fileID)
        }
    }

    func clearApprovals() {
        guard !isApplying else { return }
        confirmedFileIDs.subtract(confirmedFileIDs.filter { !pendingRecordingFileIDs.contains($0) })
    }

    func approveAndAdvance() {
        do { try refreshMembership() } catch { actionError = error.localizedDescription; return }
        guard let fileID = focusedFileID, canApprove(fileID: fileID), let index = scannedFileIDs.firstIndex(of: fileID) else { return }
        confirmedFileIDs.insert(fileID)
        let ordered = Array(scannedFileIDs.dropFirst(index + 1)) + Array(scannedFileIDs.prefix(index))
        if let nextID = ordered.first(where: { canApprove(fileID: $0) && !confirmedFileIDs.contains($0) }) {
            focus(nextID)
        } else {
            focusNotice = "All available matches are approved. Review them, then Apply when ready."
        }
    }

    func focus(_ fileID: Int64) {
        guard scannedFileIDs.contains(fileID) else { return }
        focusedFileID = fileID
        hasFocusedEntry = true
        focusNotice = nil
    }

    private func establishFocus() {
        guard !hasFocusedEntry || focusedFileID.map({ !scannedFileIDs.contains($0) }) != false else { return }
        if let fileID = scannedFileIDs.first(where: { canApprove(fileID: $0) && !confirmedFileIDs.contains($0) }) ?? scannedFileIDs.first {
            focus(fileID)
        }
    }

    func previous() {
        moveFocus(by: -1)
    }

    func next() {
        moveFocus(by: 1)
    }

    private func moveFocus(by offset: Int) {
        guard let fileID = focusedFileID, let index = scannedFileIDs.firstIndex(of: fileID), scannedFileIDs.indices.contains(index + offset) else { return }
        focus(scannedFileIDs[index + offset])
    }

    func applyConfirmed() async {
        guard !isApplying, pendingResyncBatchId == nil, !confirmedFileIDs.isEmpty else { return }
        guard confirmedFileIDs.isDisjoint(with: pendingRecordingFileIDs) else {
            actionError = "Wait for the pending recording choice before applying approved files."
            return
        }
        let payloads = scannedFileIDs.filter { confirmedFileIDs.contains($0) && !appliedFileIDs.contains($0) }.compactMap { rowModels[$0]?.payload() }
        guard !payloads.isEmpty else { return }
        isApplying = true
        actionError = nil
        cancelRecordingRequests()
        let task = Task { [self] in
            defer { isApplying = false }
            do {
                let tokens = lookupService.membershipTokens(for: payloads.map(\.fileID))
                let staleIDs = try await lookupService.staleFileIDs(for: payloads).union(payloads.map(\.fileID).filter { tokens[$0] == nil })
                let freshPayloads = payloads.filter { !staleIDs.contains($0.fileID) }
                let staleNotice = staleIDs.isEmpty ? "" : " Skipped \(staleIDs.count) file(s) that changed since scanning; scan them again."
                guard !freshPayloads.isEmpty else {
                    actionError = staleNotice.trimmingCharacters(in: .whitespaces)
                    return
                }
                let batchID = UUID().uuidString
                do {
                    try await applyBatch(freshPayloads.map { .applyMusicBrainzMatch($0) }, batchID, tokens)
                    markApplied(freshPayloads)
                    lastResult = "Applied \(freshPayloads.count) file(s)." + staleNotice
                } catch let OperationEngineError.externalSyncIncomplete(failedBatchID, underlying) {
                    markApplied(freshPayloads)
                    pendingResyncBatchId = failedBatchID
                    actionError = "Applied to the library; some external writes are incomplete: \(underlying)" + staleNotice
                }
            } catch { actionError = "Could not apply the approved files: \(error.localizedDescription)" }
        }
        await task.value
    }

    private func markApplied(_ payloads: [ApplyMusicBrainzMatchPayload]) {
        let fileIDs = Set(payloads.map(\.fileID))
        appliedFileIDs.formUnion(fileIDs)
        confirmedFileIDs.subtract(fileIDs)
    }

    func resyncPartialApply() async {
        guard !isApplying, let batchID = pendingResyncBatchId else { return }
        isApplying = true
        let task = Task { [self] in
            defer { isApplying = false }
            do {
                let outcome = try await resyncBatch(batchID)
                if outcome.queuedCount == 0 {
                    pendingResyncBatchId = nil
                    actionError = nil
                    lastResult = outcome.summaryMessage
                } else {
                    actionError = outcome.summaryMessage
                }
            } catch { actionError = "External sync failed: \(error.localizedDescription)" }
        }
        await task.value
    }

    private func cancelRecordingRequests() {
        for task in recordingTasks.values {
            task.cancel()
        }
        recordingTasks = [:]
        recordingRequests = [:]
        pendingRecordingFileIDs = []
    }

    func selectRecording(fileID: Int64, recordingID: String) async {
        guard !isApplying, !appliedFileIDs.contains(fileID), scannedFileIDs.contains(fileID) else { return }
        recordingTasks[fileID]?.cancel()
        recordingTasks[fileID] = nil
        recordingRequests[fileID] = nil
        pendingRecordingFileIDs.remove(fileID)
        selectionErrorByFileID[fileID] = nil
        if isCurrentRecording(fileID: fileID, recordingID: recordingID) {
            return
        }
        let requestID = UUID()
        let generation = scanGeneration
        recordingRequests[fileID] = requestID
        pendingRecordingFileIDs.insert(fileID)
        let task = Task { [self] in
            defer {
                if recordingRequests[fileID] == requestID {
                    recordingRequests[fileID] = nil
                    recordingTasks[fileID] = nil
                    pendingRecordingFileIDs.remove(fileID)
                }
            }
            do {
                let candidate = try await lookupService.resolveAlternative(fileID: fileID, recordingID: recordingID)
                guard generation == scanGeneration, recordingRequests[fileID] == requestID,
                      !Task.isCancelled, !isApplying, !appliedFileIDs.contains(fileID) else { return }
                if !isCurrentRecording(fileID: fileID, recordingID: candidate.recordingMBID) {
                    rowModels[fileID] = AutoTagRowModel(candidate: candidate)
                    confirmedFileIDs.remove(fileID)
                }
            } catch {
                guard generation == scanGeneration, recordingRequests[fileID] == requestID, !Task.isCancelled else { return }
                selectionErrorByFileID[fileID] = "Could not choose this recording: \(error.localizedDescription)"
            }
        }
        recordingTasks[fileID] = task
        await task.value
    }

    func isCurrentRecording(fileID: Int64, recordingID: String) -> Bool {
        guard let current = rowModels[fileID]?.candidate.recordingMBID,
              let alternatives = lookupService.recordingAlternatives[fileID] else { return false }
        let details = lookupService.recordingDetails[fileID] ?? [:]
        return alternatives.canonicalID(for: current, details: details) == alternatives.canonicalID(for: recordingID, details: details)
    }

    func matchAssessment(for fileID: Int64) -> RecordingMatchAssessment? {
        rowModels[fileID].flatMap { lookupService.matchAssessment(for: $0.candidate) }
    }

    func loadAlternativeDetails(fileID: Int64, offset: Int, limit: Int = 10) async throws -> [RecordingAlternativeDetailResult] {
        guard !isApplying, scannedFileIDs.contains(fileID) else { throw CancellationError() }
        let generation = scanGeneration
        let details = try await lookupService.loadAlternativeDetails(fileID: fileID, offset: offset, limit: limit)
        guard generation == scanGeneration, !isApplying else { throw CancellationError() }
        try Task.checkCancellation()
        return details
    }

    func ensureBrowseLoaded() async {
        guard !browseLoaded else { return }
        if let browseTask {
            await browseTask.value
        } else {
            await loadBrowsePage(0)
        }
    }

    func loadSelectionPage(_ page: Int) async {
        if selectionMode == .browse {
            await loadBrowsePage(page)
        } else {
            await performSearch(page: page)
        }
    }

    func loadBrowsePage(_ page: Int? = nil) async {
        guard !isScanning, !isApplying else { return }
        browseTask?.cancel()
        browseGeneration += 1
        let generation = browseGeneration
        let requestedPage = page ?? browsePage
        let filter = browseFilter
        let query = browseQuery
        isBrowsing = true
        browseError = nil
        let task = Task { [self] in
            do {
                let result = try await database.writer.read { database in try AutoTagFileBrowse.browse(filter: filter, page: requestedPage, query: query, in: database) }
                guard generation == browseGeneration, !Task.isCancelled else { return }
                try reconcileSelection()
                guard generation == browseGeneration, !Task.isCancelled else { return }
                browseResults = result
                browseLoaded = true
            } catch {
                guard generation == browseGeneration, !Task.isCancelled else { return }
                browseError = "Could not browse the library: \(error.localizedDescription)"
            }
            guard generation == browseGeneration else { return }
            isBrowsing = false
            browseTask = nil
        }
        browseTask = task
        await task.value
    }

    func updateBrowseQuery(_ query: String) {
        guard !isScanning, !isApplying else { return }
        browseQuery = query
        browseTask?.cancel()
        browseGeneration += 1
        let generation = browseGeneration
        isBrowsing = true
        browseTask = Task {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard generation == browseGeneration else { return }
            await loadBrowsePage(0)
        }
    }

    func setBrowseFilter(_ filter: AutoTagBrowseFilter) {
        guard !isScanning, !isApplying, filter != browseFilter else { return }
        browseGeneration += 1
        browseTask?.cancel()
        browseFilter = filter
        browseLoaded = false
        browseResults = .empty
        let generation = browseGeneration
        Task {
            guard generation == browseGeneration else { return }
            await loadBrowsePage(0)
        }
    }

    func updateSearchQuery(_ query: String) {
        guard !isScanning, !isApplying, query != searchState.query else { return }
        searchState.query = query
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        searchTask = Task { [self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard generation == searchGeneration else { return }
            await performSearch()
        }
    }

    func performSearch(page: Int = 0) async {
        guard !isScanning, !isApplying else { return }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchState.beginSearch()
        let task = Task { [self] in
            let outcome: Result<AutoTagFileSearch.Results, Error>
            do { outcome = try await .success(database.writer.read { database in try AutoTagFileSearch.search(query: query, page: page, in: database) }) }
            catch { outcome = .failure(error) }
            guard generation == searchGeneration,
                  Self.shouldPublishSearchResult(queryTaskRanFor: query, currentQuery: searchState.query, isCancelled: Task.isCancelled) else { return }
            do { try reconcileSelection() }
            catch { actionError = "Could not refresh selection: \(error.localizedDescription)" }
            guard generation == searchGeneration, !Task.isCancelled else { return }
            searchState.publish(outcome, for: query)
            searchTask = nil
        }
        searchTask = task
        await task.value
    }
}
