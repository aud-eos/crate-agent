import SwiftUI

struct SeratoConflictReviewView: View {
    @ObservedObject var model: SeratoConflictReviewModel
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(SeratoConflictMessages.review, subtitle: "Repair ambiguous saved references in Serato. Unaffected tracks remain usable.")
                .padding(density.pagePadding)
            if model.isStale {
                Text(SeratoConflictMessages.stale)
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, density.pagePadding).padding(.bottom, density.spacing)
            }
            if let error = model.actionError {
                ActionErrorMessage(message: error).padding(.horizontal, density.pagePadding).padding(.bottom, density.spacing)
            }
            LibrarySyncStatusView(state: model.state, retry: model.retry)
            Divider()
            if model.conflicts.isEmpty {
                AppEmptyState(title: "No path conflicts", detail: "The last validated library snapshot has no ambiguous saved paths.", systemImage: "checkmark.circle")
            } else {
                HStack(alignment: .top, spacing: 0) {
                    List(model.conflicts, selection: $model.selectedConflictID) { conflict in
                        VStack(alignment: .leading, spacing: density.detailSpacing) {
                            Text((conflict.id as NSString).lastPathComponent).font(.headline)
                            Text("\(conflict.occurrences.count) saved entries · \(conflict.fileIDs.count) indexed files").font(.callout).foregroundStyle(.secondary)
                        }.tag(conflict.id)
                    }.frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                        .accessibilityLabel("Path conflicts")
                    Divider()
                    ScrollView {
                        if let conflict = model.selectedConflict {
                            LazyVStack(alignment: .leading, spacing: density.spacing) {
                                Text(SeratoConflictReviewModel.guidance(conflict)).font(.headline)
                                Text(SeratoConflictMessages.repair).font(.callout)
                                ForEach(conflict.occurrences) { occurrence in
                                    Divider()
                                    Text(SeratoConflictReviewModel.describe(occurrence))
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if case .existing = occurrence.observation {
                                        Button("Show in Finder") { Task { await model.reveal(occurrence) } }
                                            .accessibilityLabel("Show saved entry \(occurrence.id + 1) in Finder")
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(density.pagePadding)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: density.spacing) {
                Button("Copy conflict details", action: model.copyDetails).disabled(model.selectedConflict == nil)
                Spacer()
                Button("Open Serato") { Task { await model.openSerato() } }
                Button("Retry Sync", action: model.retry)
            }.padding(density.pagePadding)
        }.frame(minWidth: 850, minHeight: 550)
            .background(Color(nsColor: .windowBackgroundColor)).appPresentation()
    }
}
