import SwiftUI

/// The genre, compatible-key and BPM-range filters. Menus are labelled by their state and show no indicator.
struct LibraryFacetBar: View {
    @Binding var facets: LibraryFacets
    let options: LibraryFacetOptions?
    @State private var lowerBPM = ""
    @State private var upperBPM = ""
    @State private var bpmError: String?

    var body: some View {
        WrappingHStack(spacing: 8, lineSpacing: 6) {
            genreMenu
            keyMenu
            bpmField(LibraryChecklistMessages.bpmFrom, text: $lowerBPM)
            bpmField(LibraryChecklistMessages.bpmTo, text: $upperBPM)
            Button(LibraryChecklistMessages.clearFilters) {
                lowerBPM = ""
                upperBPM = ""
                bpmError = nil
                facets = LibraryFacets()
            }
            .controlSize(.small)
            .help(LibraryChecklistMessages.clearFiltersHelp)
            .disabled(facets.isEmpty && lowerBPM.isEmpty && upperBPM.isEmpty)
            if let bpmError {
                Text(bpmError).font(.caption).foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryChecklistMessages.facetBarLabel)
        .onAppear(perform: showStoredRange)
        .onChange(of: facets.bpmRange) { _, _ in showStoredRange() }
    }

    private var genreMenu: some View {
        Menu {
            if let options {
                Button(LibraryChecklistMessages.anyGenre) { update { facets in facets.genres = [] } }
                    .disabled(facets.genres.isEmpty)
                if options.genres.isEmpty {
                    Text(LibraryChecklistMessages.noGenres)
                }
                ForEach(options.genres, id: \.self) { option in
                    Toggle(LibraryChecklistMessages.genreOption(option), isOn: Binding(get: { isChosen(option) }, set: { chosen in
                        update { facets in
                            if chosen {
                                facets.genres.formUnion(option.storedValues)
                            } else {
                                facets.genres.subtract(option.storedValues)
                            }
                        }
                    }))
                }
            } else {
                Text(LibraryChecklistMessages.loadingOptions)
            }
        } label: {
            Text(genreLabel)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .help(LibraryChecklistMessages.facetHelp)
        .accessibilityLabel(genreLabel)
    }

    private var keyMenu: some View {
        Menu {
            if let options {
                Button(LibraryChecklistMessages.anyKey) { update { facets in facets.compatibleKey = nil } }
                    .disabled(facets.compatibleKey == nil)
                if options.keys.isEmpty {
                    Text(LibraryChecklistMessages.noKeys)
                }
                ForEach(options.keys.keys.sorted(), id: \.self) { key in
                    Toggle(LibraryChecklistMessages.keyOption(key, spellings: options.keys[key] ?? []),
                           isOn: Binding(get: { facets.compatibleKey == key }, set: { chosen in
                               update { facets in facets.compatibleKey = chosen ? key : nil }
                           }))
                }
            } else {
                Text(LibraryChecklistMessages.loadingOptions)
            }
        } label: {
            Text(LibraryChecklistMessages.keyLabel(facets.compatibleKey))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .help(LibraryChecklistMessages.keyHelp)
        .accessibilityLabel(LibraryChecklistMessages.keyLabel(facets.compatibleKey))
    }

    private func bpmField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 80)
            .monospacedDigit()
            .onSubmit(applyRange)
            .help(LibraryChecklistMessages.bpmHelp)
            .accessibilityLabel(title)
    }

    private var genreLabel: String {
        guard !facets.genres.isEmpty else { return LibraryChecklistMessages.genreLabel(first: nil, others: 0) }
        let chosen = options?.genres.filter(isChosen) ?? []
        guard let first = chosen.first else {
            let stored = facets.genres.sorted { lhs, rhs in lhs.localizedStandardCompare(rhs) == .orderedAscending }
            return LibraryChecklistMessages.genreLabel(first: stored.first, others: stored.count - 1)
        }
        return LibraryChecklistMessages.genreLabel(first: first.value, others: chosen.count - 1)
    }

    private func isChosen(_ option: GenreOption) -> Bool {
        !option.storedValues.isDisjoint(with: facets.genres)
    }

    private func update(_ change: (inout LibraryFacets) -> Void) {
        var updated = facets
        change(&updated)
        facets = updated
    }

    private func applyRange() {
        let lowerText = lowerBPM.trimmingCharacters(in: .whitespaces)
        let upperText = upperBPM.trimmingCharacters(in: .whitespaces)
        guard !lowerText.isEmpty || !upperText.isEmpty else {
            bpmError = nil
            update { facets in facets.bpmRange = nil }
            return
        }
        guard let lower = lowerText.isEmpty ? 0 : Double(lowerText), let upper = upperText.isEmpty ? .greatestFiniteMagnitude : Double(upperText),
              lower.isFinite, !upper.isNaN
        else {
            bpmError = LibraryChecklistMessages.bpmNotNumber
            return
        }
        guard lower <= upper else {
            bpmError = LibraryChecklistMessages.bpmReversed
            return
        }
        bpmError = nil
        update { facets in facets.bpmRange = lower ... upper }
    }

    /// Shows the applied range, so a range cleared elsewhere clears the fields too.
    private func showStoredRange() {
        guard let range = facets.bpmRange else {
            if bpmError == nil {
                lowerBPM = ""
                upperBPM = ""
            }
            return
        }
        lowerBPM = range.lowerBound > 0 ? Self.text(range.lowerBound) : ""
        upperBPM = range.upperBound < .greatestFiniteMagnitude ? Self.text(range.upperBound) : ""
    }

    /// Plain digits that `Double(_:)` reads back, whatever the locale.
    private static func text(_ bpm: Double) -> String {
        bpm == bpm.rounded() && abs(bpm) < 1_000_000 ? String(Int(bpm)) : String(bpm)
    }
}
