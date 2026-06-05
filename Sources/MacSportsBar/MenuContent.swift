import SwiftUI

/// The dropdown shown when the menu-bar item is clicked. With `.menuBarExtraStyle(.menu)`
/// each top-level view becomes a native menu item.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.events.isEmpty {
            Text("No games right now")
        } else {
            ForEach(model.events.prefix(8)) { event in
                Text(event.displayString)
            }
        }

        Divider()

        Button("Refresh Now") {
            Task { await model.refresh() }
        }
        Button("Quit MacSportsBar") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
