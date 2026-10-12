import SwiftUI

struct MainWindowNavigation<Detail: View>: View {
    @Binding var selection: MainWindowView.Section
    let hasConflicts: Bool
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        NavigationSplitView {
            List(MainWindowView.Section.allCases.filter { section in section != .conflicts || hasConflicts || selection == .conflicts }, selection: $selection) { section in
                Label(section.displayName, systemImage: section.iconName)
                    .tag(section)
            }
            .navigationTitle("crate-agent")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail()
        }
    }
}
