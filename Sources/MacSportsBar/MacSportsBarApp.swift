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

struct MacSportsBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Text(model.menuBarText)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Makes this an *agent* app: no dock icon and no default window — it lives only in the
/// menu bar. This is the programmatic equivalent of `LSUIElement` in a bundled `.app`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
