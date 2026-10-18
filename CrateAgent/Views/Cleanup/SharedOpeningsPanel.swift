import SwiftUI

/// Recordings merged by a 120 s fingerprint collision whose full-length
/// audio differs (#205). Each card is the read-only preview of one split;
/// nothing changes until the user separates it, as one History batch.
struct SharedOpeningsPanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices

    @State private var scan: RecordingSplitScan?
    @State private var isChecking = false
    @State private var isSeparating = false
    @State private var actionError: String?
    @State private var lastResult: String?
    @State private var pendingSplit: RecordingSplitCandidate?

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Shared openings", subtitle: """
            These files share their first 120 seconds, so crate-agent treats them as one recording, but their full-length audio differs. \
            Separate them to give each version a recording of its own.
            """)
            .padding(density.pagePadding)
            Divider()
            content.disabled(isSeparating)
            Divider()
            footer
        }
        .task { await refresh() }
        .alert("Separate these recordings?", isPresented: Binding(get: { pendingSplit != nil }, set: { shown in
            if !shown {
                pendingSplit = nil
            }
        }), presenting: pendingSplit) { candidate in
            Button("Separate") { Task { await separate(candidate) } }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text(movedFilesMessage(candidate))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let actionError, scan?.candidates.isEmpty ?? true {
            ActionErrorMessage(message: actionError)
        } else if let scan, !scan.candidates.isEmpty {
            ScrollView {
                LazyVStack(spacing: density.spacing) {
                    ForEach(scan.candidates) { candidate in
                        card(candidate)
                    }
                }
                .padding(.horizontal, density.pagePadding)
                .padding(.vertical, density.spacing)
            }
        } else if scan == nil || isChecking {
            ProgressView("Checking full-length fingerprints…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            hygienePlaceholder(icon: "checkmark.seal", color: .green, headline: "No shared openings to separate",
                               detail: "Every set of files that share their first 120 seconds also matches over its full length.")
        }
    }

    private func card(_ candidate: RecordingSplitCandidate) -> some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack {
                Text("\(candidate.separates.count + 1) versions share one recording")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Separate Recordings") {
                    if candidate.movedFiles.isEmpty {
                        Task { await separate(candidate) }
                    } else {
                        pendingSplit = candidate
                    }
                }
                .controlSize(density.controlSize)
                .help("Gives each version below the first a recording of its own. Undo it from History.")
            }
            version(candidate.keeps, heading: "Keeps the shared recording")
            ForEach(Array(candidate.separates.enumerated()), id: \.offset) { _, separated in
                version(separated, heading: "Gets a recording of its own")
            }
        }
        .padding(density.spacing)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func version(_ version: RecordingSplitVersion, heading: String) -> some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            Text(heading).font(.subheadline.weight(.medium))
            ForEach(version.files) { file in
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.name)
                    Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var footer: some View {
        ActionBar {
            if let actionError, !(scan?.candidates.isEmpty ?? true) {
                ActionErrorMessage(message: actionError)
            } else if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            } else if let scan {
                Text(scan.checkingCount > 0 ? "\(scan.candidates.count) to review · checking \(scan.checkingCount) more" : "\(scan.candidates.count) to review")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Check Again") { Task { await refresh() } }
                .disabled(isChecking || isSeparating)
        }
    }

    private func movedFilesMessage(_ candidate: RecordingSplitCandidate) -> String {
        let lines = candidate.movedFiles.map { file in
            var lost = ["its current recording"]
            if file.sharedRecording?.hasMusicBrainzMatch == true {
                lost.append("its MusicBrainz match")
            }
            if file.sharedRecording?.isInSongFamily == true {
                lost.append("its song family")
            }
            return "“\(file.name)” leaves \(lost.formatted(.list(type: .and)))."
        }
        return (lines + ["Undo it from History."]).joined(separator: "\n")
    }

    private func refresh() async {
        isChecking = true
        defer { isChecking = false }
        let service = services.recordingIdentity
        do {
            scan = try await service.scan()
            try await service.checkCollidingFiles()
            scan = try await service.scan()
            actionError = nil
        } catch is CancellationError {
            return
        } catch {
            actionError = "Couldn't check shared openings: \(error.localizedDescription)"
        }
    }

    private func separate(_ candidate: RecordingSplitCandidate) async {
        isSeparating = true
        defer { isSeparating = false }
        do {
            try await services.recordingIdentity.separate(candidate)
            let count = candidate.separates.count
            lastResult = "Gave \(count) version\(count == 1 ? "" : "s") a recording of \(count == 1 ? "its" : "their") own."
            actionError = nil
            scan = try await services.recordingIdentity.scan()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
