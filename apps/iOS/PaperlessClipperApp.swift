import SwiftUI

@main
struct PaperlessClipperApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Paperless Clipper")
                .font(.title)
            Text("Settings UI lands in Phase 5 (US2).")
                .foregroundColor(.secondary)
            Text("Open Safari → Settings → Extensions to enable.")
                .foregroundColor(.secondary)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
