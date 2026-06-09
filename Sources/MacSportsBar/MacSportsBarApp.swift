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
            MenuBarLabel(presenter: model.menuBar, model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("MacSportsBar Settings", id: WindowID.settings) {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar item's label. It observes ONLY the `MenuBarPresenter` (just the composited
/// image), never the full `AppModel` — so the poll loop reassigning `events`/`favoritesDigest`
/// every few seconds doesn't re-push the label to the status item and make macOS drop it.
///
/// It also lives *in* the menu bar, so its `colorScheme` environment reflects the real
/// (wallpaper-driven) light/dark tint — the source the app's own appearance and the global Dark
/// Mode setting both missed. We forward it to the model (an unobserved reference) so the
/// composited color image tints to match. SwiftUI re-runs this view when the tint flips.
private struct MenuBarLabel: View {
    @ObservedObject var presenter: MenuBarPresenter
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = presenter.image {
                Image(nsImage: image)
            } else {
                Image(systemName: "sportscourt.fill")   // brief placeholder before the first render
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
