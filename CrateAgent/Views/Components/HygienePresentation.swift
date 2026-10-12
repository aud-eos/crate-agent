import SwiftUI

func hygienePlaceholder(
    icon: String,
    color: Color,
    headline: String,
    detail: String
) -> some View {
    AppEmptyState(title: headline, detail: detail, systemImage: icon, tint: color)
}
