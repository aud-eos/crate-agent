import SwiftUI

/// Banner shown at the top of any view whose actions write Serato
/// library files. Per Invariant 3, those writes MUST not run while
/// Serato is open or they get silently clobbered when Serato saves.
/// Renders nothing (not even its divider) while Serato is closed, so
/// views place it unconditionally.
struct SeratoRunningBanner: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    let message: String

    var body: some View {
        if seratoWatchdog.isSeratoRunning {
            HStack(spacing: density.spacing) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, density.pagePadding)
            .padding(.vertical, density.rowPadding)
            .background(Color.orange.opacity(0.1))
            Divider()
        }
    }
}

extension View {
    /// The single Invariant 3 gate for a control whose action writes
    /// Serato library files: disabled while Serato is running, with
    /// `runningHelp` explaining why. Combine with `.disabled(_:)` for
    /// the control's own preconditions.
    func seratoWriteGated(help: String, runningHelp: String) -> some View {
        modifier(SeratoWriteGate(help: help, runningHelp: runningHelp))
    }
}

private struct SeratoWriteGate: ViewModifier {
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    let help: String
    let runningHelp: String

    func body(content: Content) -> some View {
        content
            .disabled(seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning ? runningHelp : help)
    }
}
