import SwiftUI

/// Library's "Find Versions…" checklist. `SongFamilySuggester` finds and
/// applies the families; this view only holds what the user checked.
struct FindVersionsSheet: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var result: SongFamilySuggestions?
    @State private var checked: Set<String> = []
    /// Every checklist item shown so far, so a rescan keeps the user's checks
    /// and pre-checks only strong matches it has not shown before.
    @State private var shown: Set<String> = []
    @State private var actionError: String?
    @State private var notice: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: density.spacing) {
                PageHeading(FindVersionsMessages.title, subtitle: FindVersionsMessages.subtitle)
                if let actionError {
                    ActionErrorMessage(message: actionError)
                }
                if let notice {
                    ActionNoticeMessage(message: notice)
                }
                if let result {
                    notes(for: result)
                }
            }
            .padding(density.pagePadding)
            Divider()
            content
            Divider()
            footer.padding(density.pagePadding)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 680)
        .appPresentation()
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        if let result, !result.suggestions.isEmpty {
            List(result.suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion, checked: $checked)
            }
        } else if result != nil {
            Text(FindVersionsMessages.noSuggestions).foregroundStyle(.secondary).padding(density.pagePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ProgressView(FindVersionsMessages.scanning).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func notes(for result: SongFamilySuggestions) -> some View {
        if result.awaitingFingerprint > 0 {
            ActionNoticeMessage(message: FindVersionsMessages.awaitingFingerprint(result.awaitingFingerprint))
        }
        if !result.sameAudio.isEmpty {
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                ActionNoticeMessage(message: FindVersionsMessages.sameAudioHelp)
                HStack(spacing: density.spacing) {
                    Button(FindVersionsMessages.openDuplicates) {
                        services.open(.cleanup)
                        dismiss()
                    }
                    TextDisclosure(show: FindVersionsMessages.showSameAudio(result.sameAudio.count),
                                   hide: FindVersionsMessages.hideSameAudio(result.sameAudio.count))
                    {
                        ScrollView {
                            VStack(alignment: .leading, spacing: density.detailSpacing) {
                                ForEach(result.sameAudio, id: \.first?.id) { cluster in
                                    Text(cluster.map(\.title).formatted(.list(type: .and))).font(.callout)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }
        }
    }

    private var footer: some View {
        let checkedChoices = checkedChoices()
        let choices = Array(checkedChoices.prefix(SongFamilySuggester.maximumFamiliesPerApply))
        return HStack(spacing: density.spacing) {
            if let result {
                VStack(alignment: .leading, spacing: 0) {
                    Text(FindVersionsMessages.summary(suggestions: result.suggestions.count, checked: checkedChoices.count))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    if checkedChoices.count > choices.count {
                        Text(FindVersionsMessages.batchLimit(SongFamilySuggester.maximumFamiliesPerApply)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(FindVersionsMessages.rescan) { Task { await scan() } }.disabled(isWorking)
            Button(FindVersionsMessages.cancel, role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(FindVersionsMessages.apply(choices.count)) { Task { await apply(choices) } }
                .keyboardShortcut(.defaultAction)
                .disabled(choices.isEmpty || isWorking)
        }
    }

    /// The suggestions the checklist would group, each with its checked recordings.
    private func checkedChoices() -> [SongFamilySuggestionChoice] {
        (result?.suggestions ?? []).compactMap { suggestion in
            let recordings = Set(suggestion.recordings.map(\.id).filter { recordingID in
                checked.contains(SuggestionRow.itemID(suggestion, recordingID))
            })
            return SuggestionRow.isApplicable(suggestion, checkedRecordings: recordings.count, merges: checked.contains(SuggestionRow.mergeItemID(suggestion)))
                ? SongFamilySuggestionChoice(suggestion: suggestion, recordingIds: recordings) : nil
        }
    }

    private func scan() async {
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            let found = try await services.songFamilySuggester.suggestions()
            result = found
            let items = Set(found.suggestions.flatMap(SuggestionRow.itemIDs))
            let strong = Set(found.suggestions.filter { suggestion in suggestion.confidence == .high }.flatMap(SuggestionRow.itemIDs))
            checked = checked.intersection(items).union(strong.subtracting(shown))
            shown.formUnion(items)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func apply(_ choices: [SongFamilySuggestionChoice]) async {
        isWorking = true
        actionError = nil
        notice = nil
        do {
            _ = try await services.songFamilySuggester.apply(choices)
            isWorking = false
            await scan()
            notice = FindVersionsMessages.applied(choices.count)
        } catch {
            isWorking = false
            actionError = error.localizedDescription
        }
    }
}

/// One suggested family: its checkbox is mixed while only some versions are checked.
private struct SuggestionRow: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let suggestion: SongFamilySuggestion
    @Binding var checked: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            HStack(spacing: density.spacing) {
                Toggle(sources: Self.itemIDs(suggestion).map(binding), isOn: \.self) {
                    Text([suggestion.artist, suggestion.title].compactMap(\.self).joined(separator: " – ")).font(.headline)
                }
                .toggleStyle(.checkbox)
                Text(suggestion.confidence == .high ? FindVersionsMessages.high : FindVersionsMessages.medium)
                    .font(.callout).foregroundStyle(suggestion.confidence == .high ? Color.green : Color.orange)
                    .help(suggestion.confidence == .high ? FindVersionsMessages.highHelp : FindVersionsMessages.mediumHelp)
                Text(targetDescription).font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                if case let .merge(_, merged) = suggestion.target {
                    Toggle(FindVersionsMessages.mergeItem(merged.count + 1), isOn: binding(Self.mergeItemID(suggestion))).toggleStyle(.checkbox)
                }
                ForEach(suggestion.recordings) { recording in
                    Toggle(isOn: binding(Self.itemID(suggestion, recording.id))) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(recording.files) { file in fileLine(file) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                ForEach(suggestion.existingFiles) { file in
                    fileLine(file).foregroundStyle(.secondary).help(FindVersionsMessages.alreadyGrouped)
                }
                if case .newFamily = suggestion.target, (1 ..< 2).contains(checkedRecordings) {
                    Text(FindVersionsMessages.needsTwoVersions).font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, density.rowPadding)
    }

    private var checkedRecordings: Int {
        suggestion.recordings.count { recording in checked.contains(Self.itemID(suggestion, recording.id)) }
    }

    private var targetDescription: String {
        switch suggestion.target {
        case .newFamily: FindVersionsMessages.newFamily
        case .family: FindVersionsMessages.addsToFamily(suggestion.existingFiles.first?.title ?? suggestion.title)
        case let .merge(_, merged): FindVersionsMessages.mergesFamilies(merged.count + 1)
        }
    }

    private func fileLine(_ file: SongFamilySuggestedFile) -> some View {
        Text(FindVersionsMessages.fileLine(title: file.title, label: file.versionLabel, length: file.length)).font(.callout)
    }

    private func binding(_ itemID: String) -> Binding<Bool> {
        Binding(get: { checked.contains(itemID) }, set: { isChecked in
            if isChecked {
                checked.insert(itemID)
            } else {
                checked.remove(itemID)
            }
        })
    }

    static func itemID(_ suggestion: SongFamilySuggestion, _ recordingID: String) -> String {
        "\(suggestion.id)|\(recordingID)"
    }

    static func mergeItemID(_ suggestion: SongFamilySuggestion) -> String {
        "\(suggestion.id)|merge"
    }

    static func itemIDs(_ suggestion: SongFamilySuggestion) -> [String] {
        let merge = if case .merge = suggestion.target {
            [mergeItemID(suggestion)]
        } else {
            [String]()
        }
        return merge + suggestion.recordings.map { recording in itemID(suggestion, recording.id) }
    }

    /// A new family needs two checked versions, an existing one a checked
    /// addition, and a merge its merge checked.
    static func isApplicable(_ suggestion: SongFamilySuggestion, checkedRecordings: Int, merges: Bool) -> Bool {
        switch suggestion.target {
        case .newFamily: checkedRecordings >= 2
        case .family: checkedRecordings >= 1
        case .merge: merges
        }
    }
}
