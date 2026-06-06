import SwiftUI
import AppKit

/// The dropdown shown when the menu-bar item is clicked. With `.menuBarExtraStyle(.menu)`
/// each top-level view becomes a native menu item.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let digest = model.favoritesDigest
        let digestIDs = Set(digest.map(\.id))
        let others = model.events.filter { !digestIDs.contains($0.id) }

        if !digest.isEmpty {
            Text("Favorites")
            ForEach(digest.prefix(12)) { event in
                gameRow(event)
            }
        }

        if !others.isEmpty {
            if !digest.isEmpty { Divider() }
            ForEach(others.prefix(8)) { event in
                gameRow(event)
            }
        }

        if digest.isEmpty && others.isEmpty {
            Text("No games right now")
        }

        Divider()

        Button("Refresh Now") {
            Task { await model.refresh() }
        }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.settings)
        }
        .keyboardShortcut(",")
        Button("Quit MacSportsBar") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// A clickable game row that pins/unpins the game in the menu bar; the pinned one shows 📌.
    private func gameRow(_ event: SportEvent) -> some View {
        Button {
            model.togglePin(event.id)
        } label: {
            Label(model.isPinned(event.id) ? "\(event.displayString)  📌" : event.displayString,
                  systemImage: event.league.symbolName)
        }
    }
}
