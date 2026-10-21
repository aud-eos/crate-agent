import SwiftUI

/// The review before a batch removal: how many files, how much space it frees, which files, and what happens.
struct LibraryRemovalReviewSheet: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let plan: LibraryBatchRemoval.Plan
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            Text(LibraryRemovalMessages.reviewTitle(plan.files.count, frees: plan.totalBytes)).font(.title3.weight(.semibold))
            Text(LibraryRemovalMessages.reviewBody).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                ForEach(plan.files.prefix(LibraryRemovalMessages.shownNames), id: \.path) { file in
                    Text(file.displayName).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                if plan.files.count > LibraryRemovalMessages.shownNames {
                    Text(LibraryRemovalMessages.andMore(plan.files.count - LibraryRemovalMessages.shownNames)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            HStack {
                Spacer()
                Button(LibraryRemovalMessages.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(LibraryRemovalMessages.confirm, role: .destructive, action: confirm)
            }
        }
        .padding(density.pagePadding)
        .frame(width: 520)
    }
}
