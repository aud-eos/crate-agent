import SwiftUI

struct AutoTagRecordingChooser: View {
    @ObservedObject var session: AutoTagSession
    let fileID: Int64
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @State private var visibleCount = 10
    @State private var request = DetailRequest(offset: 0, limit: 10)
    @State private var loadingIDs: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var pageError: String?
    @State private var isLoading = true

    private struct DetailRequest: Equatable {
        var id = UUID()
        let offset: Int
        let limit: Int
    }

    private var alternatives: RecordingAlternatives? {
        session.lookupService.recordingAlternatives[fileID]
    }

    private var details: [String: MBRecordingDetails] {
        session.lookupService.recordingDetails[fileID] ?? [:]
    }

    private var visibleAlternatives: [RecordingAlternative] {
        let requestedIDs = Set(alternatives?.entries.prefix(visibleCount).map(\.recordingID) ?? [])
        return alternatives?.collapsed(using: details).filter { alternative in requestedIDs.contains(alternative.recordingID) } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: density.spacing) {
                PageHeading("Choose recording", subtitle: "Recordings returned by this file’s audio lookup, including lower-scoring alternatives.")
                Text("Changing recording resets field choices and the release selection, and clears approval. A failed load keeps your current proposal and edits.")
                    .font(.body)
                Text("Audio match is the AcoustID fingerprint score, not verification of tags, release or version. IDs from the same lookup result share its score. Known aliases are combined as details load; unresolved IDs may still refer to the same recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = session.selectionErrorByFileID[fileID] {
                    ActionErrorMessage(message: error)
                }
                if let pageError {
                    ActionErrorMessage(message: pageError)
                    Button("Retry page") { beginRequest(offset: request.offset, limit: request.limit) }
                        .disabled(isLoading || session.isApplying)
                }
                if session.pendingRecordingFileIDs.contains(fileID) {
                    ProgressView("Loading the selected recording and its releases…")
                }
            }
            .padding(density.pagePadding)
            Divider()
            List(visibleAlternatives) { alternative in
                alternativeRow(alternative)
                    .padding(.vertical, density.rowPadding)
            }
            .listStyle(.inset)
            Divider()
            ActionBar {
                Text("Showing \(min(visibleCount, alternatives?.entries.count ?? 0)) of \(alternatives?.entries.count ?? 0) returned IDs")
                    .font(.callout.monospacedDigit())
            } actions: {
                if visibleCount < (alternatives?.entries.count ?? 0) {
                    Button("Load more (\(min(10, (alternatives?.entries.count ?? 0) - visibleCount)))") {
                        let offset = visibleCount
                        visibleCount += 10
                        beginRequest(offset: offset, limit: 10)
                    }
                    .disabled(isLoading || session.isApplying)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 500, idealHeight: 700)
        .appPresentation()
        .task(id: request) { await loadDetails(request) }
    }

    private func alternativeRow(_ alternative: RecordingAlternative) -> some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            if let detail = details[alternative.recordingID] {
                TrackHeading(artist: detail.creditedArtistName.isEmpty ? "Artist not supplied" : detail.creditedArtistName,
                             title: detail.title.isEmpty ? "Title not supplied" : detail.title, filename: alternative.recordingID)
                Text(detail.disambiguation.flatMap { value in value.isEmpty ? nil : value } ?? "Version information not supplied")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(detail.durationMilliseconds.map { milliseconds in
                    let seconds = max(0, milliseconds / 1000)
                    return "Duration: \(seconds / 60):\(String(format: "%02d", seconds % 60))"
                } ?? "Duration not supplied")
                    .font(.callout)
            } else {
                Text("Recording details unavailable").font(.headline)
                Text(alternative.recordingID).font(.callout).textSelection(.enabled)
            }
            Text("Audio match: \(alternative.score, format: .percent.precision(.fractionLength(0)))")
                .font(.body.monospacedDigit())
            Text(isPlausible(alternative) ? "Plausible by lookup score — review recording choice" : "Lower-scoring alternative — review carefully")
                .font(.callout)
                .foregroundStyle(.secondary)
            if loadingIDs.contains(alternative.recordingID) {
                ProgressView("Loading details…")
            } else if let error = errors[alternative.recordingID] {
                ActionErrorMessage(message: error)
                Button("Retry details") { retry(alternative) }
                    .disabled(isLoading || session.isApplying)
            }
            DisclosureGroup("Lookup identifiers") {
                VStack(alignment: .leading, spacing: density.detailSpacing) {
                    Text("Returned recording: \(alternative.recordingID)")
                    if let detail = details[alternative.recordingID] {
                        Text("Canonical recording: \(detail.id)")
                    }
                    Text("AcoustID result: \(alternative.acoustID)")
                }
                .font(.callout)
                .textSelection(.enabled)
            }
            if session.isCurrentRecording(fileID: fileID, recordingID: alternative.recordingID) {
                StatusBadge(title: "Current recording", systemImage: "checkmark.circle.fill", tint: .green)
                if session.pendingRecordingFileIDs.contains(fileID) {
                    Button("Keep this recording") {
                        Task { await session.selectRecording(fileID: fileID, recordingID: alternative.recordingID) }
                    }
                    .disabled(session.isApplying || session.appliedFileIDs.contains(fileID))
                }
            } else {
                Button("Use this recording") {
                    Task { await session.selectRecording(fileID: fileID, recordingID: alternative.recordingID) }
                }
                .disabled(session.isApplying || session.appliedFileIDs.contains(fileID))
            }
        }
    }

    private func isPlausible(_ alternative: RecordingAlternative) -> Bool {
        alternatives?.isPlausible(alternative) ?? false
    }

    private func retry(_ alternative: RecordingAlternative) {
        guard let offset = alternatives?.entries.firstIndex(where: { entry in entry.recordingID == alternative.recordingID }) else { return }
        beginRequest(offset: offset, limit: 1)
    }

    private func beginRequest(offset: Int, limit: Int) {
        isLoading = true
        request = DetailRequest(offset: offset, limit: limit)
    }

    private func loadDetails(_ request: DetailRequest) async {
        let requestedIDs = Set(alternatives?.entries.dropFirst(request.offset).prefix(request.limit).map(\.recordingID) ?? [])
        loadingIDs = requestedIDs
        pageError = nil
        defer {
            if self.request.id == request.id {
                loadingIDs = []
                isLoading = false
            }
        }
        do {
            let results = try await session.loadAlternativeDetails(fileID: fileID, offset: request.offset, limit: request.limit)
            try Task.checkCancellation()
            guard self.request.id == request.id else { return }
            for result in results {
                switch result.state {
                case .loaded: errors.removeValue(forKey: result.alternative.recordingID)
                case let .failed(message): errors[result.alternative.recordingID] = message
                }
            }
        } catch is CancellationError {
        } catch {
            guard self.request.id == request.id, !Task.isCancelled else { return }
            pageError = "Could not load recording details: \(error.localizedDescription)"
        }
    }
}
