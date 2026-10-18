import SwiftUI

struct LibrarySyncStatusView: View {
    let state: SeratoLibrarySyncSession.State
    let retry: () -> Void
    var phase: SeratoLibrarySyncSession.SyncPhase?
    var fileInfoFailures: [String] = []
    var progress: LibraryScanner.ScanProgress?
    @State private var reviewingFileInfo = false
    var hasConflicts = false
    var review: (() -> Void)?
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        HStack(spacing: density.spacing) {
            if case .reconciling = state {
                ProgressView().controlSize(density.controlSize)
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let completed = progress?.completedFileCount, let total = progress?.seratoReferenceCount {
                    Text("\(completed) / \(total) files checked").font(.caption.monospacedDigit())
                }
                if let first = fileInfoFailures.first {
                    Text("File-info errors: \(fileInfoFailures.count) · \(first)")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Spacer(minLength: density.spacing)
            if !fileInfoFailures.isEmpty {
                Button("Review file-info errors") { reviewingFileInfo = true }
            }
            if hasConflicts, let review {
                Button(SeratoConflictMessages.review, action: review)
            }
            if case .failed = state {
                Button("Retry Sync", action: retry)
            }
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.rowPadding)
        .background(color.opacity(0.06))
        .sheet(isPresented: $reviewingFileInfo) {
            VStack(alignment: .leading, spacing: density.spacing) {
                HStack {
                    Text("File-info read errors").font(.headline)
                    Spacer()
                    Button("Done") { reviewingFileInfo = false }
                }
                Text("These files will be retried during the next sync. Their previous library information remains available.")
                    .font(.callout).foregroundStyle(.secondary)
                List(Array(fileInfoFailures.enumerated()), id: \.offset) { failure in
                    Text(failure.element).textSelection(.enabled)
                }
            }
            .padding(density.pagePadding)
            .frame(minWidth: 620, minHeight: 320)
        }
    }

    private var message: String {
        switch state {
        case .idle: "Saved library is available for browsing. Validation is paused."
        case .waitingForSerato: "Waiting for Serato to close before checking its saved library."
        case .reconciling: (phase?.rawValue ?? "Checking saved Serato membership") + "…"
        case let .failed(message): message
        case let .ready(summary):
            "Library synced · \(summary.retired) removed from Serato · \(summary.reactivated) activated · \(summary.unavailable) unavailable"
                + (summary.pathConflictCount > 0 ? " · \(summary.pathConflictCount) path conflicts · \(summary.conflictBlockedWriteCount) changes waiting for repair" : "")
                + SeratoWriteDisposition.allCases.filter { disposition in summary.notAppliedWrites[disposition] > 0 }
                .map { disposition in " · " + SeratoWriteDispositionMessages.summary(disposition, count: summary.notAppliedWrites[disposition]) }.joined()
                + (summary.notAppliedWrites.unrecognized > 0 ? " · " + SeratoWriteDispositionMessages.unrecognizedSummary(count: summary.notAppliedWrites.unrecognized) : "")
                + (summary.trashChangedFileIDs.isEmpty ? "" : " · \(summary.trashChangedFileIDs.count) changed in Trash, checked next sync")
                + (summary.trashUncheckedFileIDs.isEmpty ? "" : " · \(summary.trashUncheckedFileIDs.count) missing, but Trash couldn't be checked: grant Full Disk Access")
                + (summary.duplicateCleanupMessage.map { " · " + $0 } ?? "")
        }
    }

    private var symbol: String {
        switch state {
        case .idle: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .waitingForSerato: "clock"
        case .reconciling: "arrow.triangle.2.circlepath"
        case let .ready(summary): summary.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .idle: .secondary
        case .failed: .red
        case .waitingForSerato: .orange
        case .reconciling: .accentColor
        case let .ready(summary): summary.needsAttention ? .orange : .secondary
        }
    }
}

enum AppDensity: String, CaseIterable, Identifiable {
    case comfortable
    case compact

    var id: String {
        rawValue
    }

    var title: String {
        self == .comfortable ? "Comfortable" : "Compact"
    }

    var spacing: CGFloat {
        self == .comfortable ? 12 : 8
    }

    var detailSpacing: CGFloat {
        self == .comfortable ? 6 : 4
    }

    var rowPadding: CGFloat {
        self == .comfortable ? 8 : 4
    }

    var pagePadding: CGFloat {
        self == .comfortable ? 20 : 14
    }

    var minimumRowHeight: CGFloat {
        self == .comfortable ? 38 : 28
    }

    var controlSize: ControlSize {
        self == .comfortable ? .regular : .small
    }
}

enum AppPresentation {
    static let mainWindowID = "main"
    static let densityPreference = "appearance.density"
}

struct DensityPicker: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        Picker("Density", selection: $density) {
            ForEach(AppDensity.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .accessibilityLabel("Display density")
        .help("Adjust spacing throughout the app. Your selections stay unchanged.")
    }
}

private struct AppPresentationModifier: ViewModifier {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    func body(content: Content) -> some View {
        content
            .font(.body)
            .controlSize(density.controlSize)
            .environment(\.defaultMinListRowHeight, density.minimumRowHeight)
    }
}

extension View {
    func appPresentation() -> some View {
        modifier(AppPresentationModifier())
    }
}

struct PageHeading: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TrackHeading: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    var artist: String?
    var title: String?
    let filename: String
    var prominent = false

    private var identity: String {
        let readableTitle = title.flatMap { value in value.isEmpty ? nil : value } ?? filename
        guard let artist, !artist.isEmpty else { return readableTitle }
        return "\(artist) — \(readableTitle)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            Text(identity)
                .font(prominent ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if identity != filename {
                Text(filename)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(density == .comfortable ? 2 : 1)
                    .truncationMode(.middle)
                    .help(filename)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrackDisplayIdentity {
    let artist: String?
    let title: String?

    static func index(_ files: [some HygieneFileSource]) -> [String: TrackDisplayIdentity] {
        files.reduce(into: [:]) { result, file in
            result[file.path] = TrackDisplayIdentity(artist: file.artist, title: file.title)
        }
    }
}

struct MetadataComparison: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let current: String?
    let proposed: String?
    var field: String?
    var emptyLabel = "Not set"
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            if let field {
                Text(field).font(.headline)
            }
            Grid(alignment: .topLeading, horizontalSpacing: density.spacing, verticalSpacing: density.detailSpacing) {
                valueRow("Current", value: current)
                valueRow("Proposed", value: proposed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(_ label: String, value: String?) -> some View {
        GridRow(alignment: .top) {
            Text(label).font(.callout).foregroundStyle(.secondary).fixedSize()
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? emptyLabel)
                .font(prominent ? .title3 : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel("\(label): \(value.flatMap { $0.isEmpty ? nil : $0 } ?? emptyLabel)")
        }
    }
}

struct ActionBar<Status: View, Actions: View>: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @ViewBuilder let status: Status
    @ViewBuilder let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: density.spacing) {
                status.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: density.spacing)
                HStack(spacing: density.spacing) { actions }.fixedSize()
            }
            VStack(alignment: .leading, spacing: density.spacing) {
                status.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: density.spacing) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .font(.body)
        .controlSize(density.controlSize)
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.spacing)
    }
}

struct AppEmptyState: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: density.spacing) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(density.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBadge: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct ActionErrorMessage: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: density.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Error: \(message)")
        .help(message)
    }
}
