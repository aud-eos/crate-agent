import SwiftUI

/// One-line rendering of `ActivityLog.latest`, shared by the main
/// window's activity strip and the menu bar popover so both surfaces
/// describe the same entry the same way.
struct ActivityEntrySummary: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let entry: ActivityLog.Entry?

    var body: some View {
        HStack(spacing: density.spacing) {
            if let entry {
                Text(entry.category.displayName)
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(entry.category.tint.opacity(0.18)))
                    .foregroundStyle(entry.category.tint)
                Text(entry.message)
                    .font(.callout)
                    .lineLimit(density == .comfortable ? 2 : 1)
                    .truncationMode(.middle)
                    .help(entry.message)
                Spacer(minLength: 8)
                Text(entry.timestamp, style: .relative)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("ago")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                Text("Idle — actions will log here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// Color tint per activity category — single source of truth for
/// every surface that renders `ActivityLog` entries.
extension ActivityLog.Category {
    var tint: Color {
        switch self {
        case .hygiene: .blue
        case .duplicate: .orange
        case .rename: .purple
        case .fingerprint: .pink
        case .sync: .teal
        case .scan: .green
        case .general: .gray
        }
    }
}
