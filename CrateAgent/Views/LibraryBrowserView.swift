import SwiftUI

struct LibraryBrowserView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("crate-agent")
                .font(.title)
            Text("Library browser will live here.")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 800, minHeight: 600)
        .padding()
    }
}

#Preview {
    LibraryBrowserView()
}
