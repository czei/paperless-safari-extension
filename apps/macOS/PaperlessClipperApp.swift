import SwiftUI

@main
struct PaperlessClipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PlaceholderView()
                .onOpenURL { url in
                    URLSchemeHandler.shared.handle(url: url)
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            URLSchemeHandler.shared.handle(url: url)
        }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Paperless Clipper")
                .font(.title)
            Text("T019 prototype: rendered PDFs are written to the App Group cache.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("Real upload to Paperless lands in T044.")
                .foregroundColor(.secondary)
                .font(.callout)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 220)
    }
}
