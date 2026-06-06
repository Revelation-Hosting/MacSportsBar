import SwiftUI
import AppKit

/// Process entry point. Normally launches the SwiftUI menu-bar app; with `--smoke-test`
/// it runs a one-shot fetch-and-print against the live feed and exits (handy for
/// verifying the fetch → decode → format pipeline headlessly, e.g. in CI).
@main
enum Entry {
    static func main() async {
        if CommandLine.arguments.contains("--smoke-test") {
            await SmokeTest.run()
            return
        }
        MacSportsBarApp.main()
    }
}

enum WindowID {
    static let settings = "settings"
}

struct MacSportsBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // The status item shows a label as EITHER text or an image, never both (and inline
        // images inside a Text are dropped). So we feed it one pre-composited image.
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("MacSportsBar Settings", id: WindowID.settings) {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar item's label. It lives *in* the menu bar, so its `colorScheme` environment
/// reflects the menu bar's real (wallpaper-driven) light/dark tint — the source of truth the
/// app's own appearance and the global Dark Mode setting both failed to give us. We forward it
/// to the model so the composited color-logo image tints its glyph + text to match. SwiftUI
/// re-runs this view when the tint flips, so the bar re-colors itself with no manual observer.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = model.menuBarImage {
                Image(nsImage: image)
            } else {
                Text(model.menuBarText)
            }
        }
        .onAppear { model.menuBarColorScheme = colorScheme }
        .onChange(of: colorScheme) { _, newValue in model.menuBarColorScheme = newValue }
    }
}

/// Makes this an *agent* app: no dock icon and no default window — it lives only in the
/// menu bar. This is the programmatic equivalent of `LSUIElement` in a bundled `.app`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
