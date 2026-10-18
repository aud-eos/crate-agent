import SwiftUI

/// A link-style button whose title says what pressing it does, used in place
/// of a disclosure triangle or chevron. It reports its expanded state to
/// assistive technology and animates only when reduced motion is off.
struct DisclosureButton: View {
    let showTitle: String
    let hideTitle: String
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(isExpanded ? hideTitle : showTitle) {
            withAnimation(reduceMotion ? nil : .default) {
                isExpanded.toggle()
            }
        }
        .buttonStyle(.link)
        .accessibilityValue(isExpanded ? DisclosureMessages.expanded : DisclosureMessages.collapsed)
    }
}

/// A `DisclosureButton` with the content it reveals below it.
struct TextDisclosure<Content: View>: View {
    private let showTitle: String
    private let hideTitle: String
    private let externalExpanded: Binding<Bool>?
    private let content: Content
    @State private var localExpanded = false
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    /// Without `isExpanded`, the disclosure keeps its own state, collapsed at first.
    init(show showTitle: String, hide hideTitle: String, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.showTitle = showTitle
        self.hideTitle = hideTitle
        externalExpanded = isExpanded
        self.content = content()
    }

    private var isExpanded: Binding<Bool> {
        externalExpanded ?? $localExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            DisclosureButton(showTitle: showTitle, hideTitle: hideTitle, isExpanded: isExpanded)
            if isExpanded.wrappedValue {
                content
            }
        }
    }
}
