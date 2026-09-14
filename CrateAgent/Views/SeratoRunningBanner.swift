import SwiftUI

/// Banner shown at the top of any panel whose Apply action writes
/// Serato library files. Per Invariant 3, those writes MUST not run
/// while Serato is open or they get silently clobbered when Serato
/// saves. Each panel passes its own message so the prompt is
/// specific to the operation ("…before fixing whitespace" /
/// "…before resolving duplicates").
///
/// The matching Apply button is gated separately via
/// `.disabled(seratoWatchdog.isSeratoRunning)` with a tooltip —
/// this view is the always-visible top-of-panel hint that explains
/// why the button is disabled.
struct SeratoRunningBanner: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let message: String

    var body: some View {
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
    }
}
