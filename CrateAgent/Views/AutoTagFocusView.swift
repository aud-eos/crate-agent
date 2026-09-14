import SwiftUI

struct AutoTagFocusView<Content: View>: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let position: Int
    let total: Int
    let canApprove: Bool
    let isApproved: Bool
    let navigationEnabled: Bool
    let notice: String?
    let previous: () -> Void
    let next: () -> Void
    let approveAndAdvance: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ActionBar {
                Text("Track \(position) of \(total)")
                    .font(.body.monospacedDigit())
            } actions: {
                Button("Previous", systemImage: "chevron.left", action: previous)
                    .disabled(position <= 1 || !navigationEnabled)
                Button("Next", systemImage: "chevron.right", action: next)
                    .disabled(position >= total || !navigationEnabled)
                Button(isApproved ? "Approved — Next Ready" : "Approve & Next", action: approveAndAdvance)
                    .disabled(!canApprove)
                    .help("Approve this proposal and move to the next ready, unapproved match. No tags are written.")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: density.spacing) {
                    if let notice {
                        Label(notice, systemImage: "checkmark.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    content
                }
                .padding(density.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
