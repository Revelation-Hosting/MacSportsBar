import SwiftUI
import AppKit

/// The dropdown shown when the menu-bar item is clicked. With `.menuBarExtraStyle(.menu)`
/// each top-level view becomes a native menu item, and a nested `Menu` becomes a flyout.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let layout = MenuLayout(digest: model.favoritesDigest, events: model.events)

        if !layout.favorites.isEmpty {
            Text("Favorites")
            ForEach(layout.favorites) { event in
                gameRow(event)
            }
        }

        if !layout.leagues.isEmpty {
            if !layout.favorites.isEmpty { Divider() }
            ForEach(layout.leagues) { group in
                Menu {
                    section("Live", group.live)
                    section("Upcoming", group.upcoming)
                    section("Final", group.finals)
                } label: {
                    Label(group.title, systemImage: group.league.symbolName)
                }
            }
        }

        if layout.favorites.isEmpty && layout.leagues.isEmpty {
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

    /// One state's games inside a league flyout, under its own header; nothing when empty.
    @ViewBuilder
    private func section(_ title: String, _ events: [SportEvent]) -> some View {
        if !events.isEmpty {
            Section(title) {
                ForEach(events) { event in
                    gameRow(event)
                }
            }
        }
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

/// How the dropdown is organised: your favorites at the top level, and every other game the
/// display filters keep (a Top-25 matchup, a league shown in full) in a flyout per league.
///
/// This replaced a single flat list capped at eight rows and ordered only by priority, where
/// one busy league starved the rest: on a Saturday night fifteen upcoming NFL games outranked
/// every college final, so the Top-25 results a user had asked for never appeared at all.
/// Per-league flyouts keep the top level short without dropping anything. Pure — a tested seam.
struct MenuLayout {
    /// Favorite games, top level: the ±24h digest first, then any favorite further out (a game
    /// later in the week), which would otherwise be buried in its league's flyout.
    let favorites: [SportEvent]
    /// Everything else, one group per league, in catalog order so each flyout stays put.
    let leagues: [LeagueGroup]

    /// Most favorites rows shown at the top level.
    static let favoritesLimit = 12

    struct LeagueGroup: Identifiable {
        let league: LeagueID
        let live: [SportEvent]
        /// Soonest first.
        let upcoming: [SportEvent]
        /// Most recent first.
        let finals: [SportEvent]

        var id: String { league.league }

        /// `NCAAF · 3 live`, or just the league name when nothing is on.
        var title: String {
            live.isEmpty ? league.displayName : "\(league.displayName) · \(live.count) live"
        }
    }

    /// - Parameters:
    ///   - digest: the ±24h favorites window, already in chronological order.
    ///   - events: every displayed game (the per-league filters already applied).
    ///   - leagueOrder: league slugs in the order their flyouts appear.
    init(digest: [SportEvent], events: [SportEvent],
         leagueOrder: [String] = LeagueCatalog.all.map(\.id)) {
        let digestIDs = Set(digest.map(\.id))
        let laterFavorites = events
            .filter { $0.isFavorite && !digestIDs.contains($0.id) }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        favorites = Array((digest + laterFavorites).prefix(Self.favoritesLimit))

        // A favorite past the row limit falls through to its flyout rather than vanishing.
        let shownIDs = Set(favorites.map(\.id))
        let rest = events.filter { !shownIDs.contains($0.id) }
        let byLeague = Dictionary(grouping: rest, by: \.league.league)
        let order = leagueOrder + byLeague.keys.filter { !leagueOrder.contains($0) }.sorted()
        leagues = order.compactMap { slug in
            guard let events = byLeague[slug], let league = events.first?.league else { return nil }
            return LeagueGroup(
                league: league,
                live: events.filter(\.isLive),
                upcoming: events.filter { if case .pre = $0.state { return true } else { return false } }
                    .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) },
                finals: events.filter(\.isFinal)
                    .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
        }
    }
}
