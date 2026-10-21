import SwiftUI

/// One toggle per popularity source, naming what each receives. Shown once from the Library when a
/// popularity column is sorted while every source is off, and reused by Settings.
struct PopularitySourceToggles: View {
    let preferences: PreferencesStore
    /// Refreshed when a source is switched on; Settings has none and leaves it to the next scheduled pass.
    var service: PopularityService?
    @State private var enabled: [PopularitySource: Bool] = [:]

    var body: some View {
        ForEach(PopularitySource.allCases, id: \.rawValue) { source in
            Toggle(isOn: binding(for: source)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PopularityMessages.name(source))
                    Text(PopularityMessages.receives(source)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        .onAppear {
            for source in PopularitySource.allCases {
                enabled[source] = preferences.isPopularitySourceEnabled(source)
            }
        }
    }

    private func binding(for source: PopularitySource) -> Binding<Bool> {
        Binding(get: { enabled[source] ?? false }, set: { isOn in
            enabled[source] = isOn
            preferences.setPopularitySource(source, enabled: isOn)
            if let service {
                Task { await service.refresh() }
            }
        })
    }
}

struct PopularitySourcesSheet: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let preferences: PreferencesStore
    let service: PopularityService
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing * 2) {
            Text(PopularityMessages.sheetTitle).font(.title2.weight(.semibold))
            Text(PopularityMessages.sheetBody).fixedSize(horizontal: false, vertical: true)
            PopularitySourceToggles(preferences: preferences, service: service)
            HStack {
                Spacer()
                Button(CommonLabels.done, action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(density.pagePadding)
        .frame(width: 480)
        .onAppear { preferences.popularityPromptShown = true }
    }
}
