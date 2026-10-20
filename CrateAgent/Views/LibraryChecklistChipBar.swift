import SwiftUI

/// Single-select checklist chips with live file counts. Pressing the chosen chip again clears it.
struct LibraryChecklistChipBar: View {
    @Binding var chip: ChecklistChip?
    let counts: [ChecklistChip: ChecklistChipCount]?
    let neverPlayedAvailable: Bool
    /// Why Never played is unavailable when `neverPlayedAvailable` is false.
    var neverPlayedUnavailableReason = LibraryChecklistMessages.neverPlayedUnavailable

    var body: some View {
        WrappingHStack(spacing: 6, lineSpacing: 6) {
            ForEach(ChecklistChip.allCases) { option in
                chipButton(option)
            }
            if !neverPlayedAvailable {
                Text(LibraryChecklistMessages.unavailableNote(neverPlayedUnavailableReason))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryChecklistMessages.chipBarLabel)
    }

    @ViewBuilder
    private func chipButton(_ option: ChecklistChip) -> some View {
        let isSelected = chip == option
        let isAvailable = option != .neverPlayed || neverPlayedAvailable
        let button = Button(LibraryChecklistMessages.chipLabel(option, count: counts?[option])) {
            chip = isSelected ? nil : option
        }
        .controlSize(.small)
        .monospacedDigit()
        .disabled(!isAvailable && !isSelected)
        .help(isAvailable ? LibraryChecklistMessages.chipHelp(option) : neverPlayedUnavailableReason)
        .accessibilityLabel(LibraryChecklistMessages.chipAccessibilityLabel(option, count: counts?[option]))
        .accessibilityHint(isAvailable ? LibraryChecklistMessages.chipHelp(option) : neverPlayedUnavailableReason)
        if isSelected {
            button.buttonStyle(.borderedProminent).accessibilityAddTraits(.isSelected)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
