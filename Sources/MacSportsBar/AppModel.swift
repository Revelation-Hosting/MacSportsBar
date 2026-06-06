import SwiftUI
import Combine
import AppKit

/// Owns the polling loop, the ranked event list, and the cycling/truncation logic that
/// decides the single string shown in the menu bar. Reads everything user-tunable from the
/// shared `Settings` and reacts live as the user changes them.
@MainActor
final class AppModel: ObservableObject {
    /// The single string rendered in the menu bar.
    @Published var menuBarText: String = "Loading…"
    /// SF Symbol shown beside the menu-bar text — the current event's league glyph.
    @Published var menuBarSymbol: String = "sportscourt.fill"
    /// Pre-rendered menu-bar label (glyph + score) as one template image. The status item
    /// shows a label as *either* text or an image — never both — so we composite them.
    @Published var menuBarImage: NSImage?
    /// Full ranked list, surfaced in the dropdown menu.
    @Published var events: [SportEvent] = []
    /// Favorite teams' games across ±24h (recent finals, live, upcoming) — the dropdown digest.
    @Published var favoritesDigest: [SportEvent] = []

    private let client = ESPNClient()
    private let notifications = NotificationManager()
    private let logos = LogoCache()
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()

    private var pollTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var cycleIndex = 0
    private var cycleCandidates: [SportEvent] = []
    /// Latest fetched + ranked events, before the favorites-only display filter is applied.
    private var lastRanked: [SportEvent] = []
    /// Cached yesterday/tomorrow favorite games (static, so refetched on a long throttle).
    private var adjacentFavorites: [SportEvent] = []
    private var adjacentFetchedAt: Date?
    /// Logo URLs + per-team breakdown of the currently-displayed matchup, for the menu-bar
    /// team-logos layout.
    private var currentAwayLogo: URL?
    private var currentHomeLogo: URL?
    private var currentMatchup: SportEvent.Matchup?

    /// How fast the menu bar rotates when several events are relevant at once.
    private let cyclePeriod: Duration = .seconds(8)

    /// Poll cadence when nothing relevant is live (spec §7 idle tier).
    private let idleInterval: Duration = .seconds(300)
    /// Cadence chosen after the last fetch, based on what's currently live.
    private var currentInterval: Duration = .seconds(30)

    init(settings: Settings = .shared) {
        self.settings = settings
        observeSettings()
        logos.onLoad = { [weak self] in self?.updateMenuBar() }
        if settings.notifyFavorites { notifications.requestAuthorizationIfNeeded() }
        startPolling()
        startCycling()
    }

    // MARK: - Settings reactivity

    private func observeSettings() {
        // Data-affecting changes → rebuild adapters and refetch. Debounced so typing in the
        // favorites field doesn't fire a request per keystroke.
        let dataChanges: [AnyPublisher<Void, Never>] = [
            settings.$enabledLeagues.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$favorites.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$refreshSeconds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$teamFavorites.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(dataChanges)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.adjacentFetchedAt = nil  // favorites/leagues changed → rebuild the window
                self?.startPolling()
            }
            .store(in: &cancellables)

        // Display-only changes → re-derive the shown set from the last fetch (no refetch).
        let displayChanges: [AnyPublisher<Void, Never>] = [
            settings.$maxLength.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$cycleFinished.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$cycleUpcoming.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$pinnedEventID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$favoritesOnly.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$showTeamLogos.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(displayChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyDisplay() }
            .store(in: &cancellables)

        // Request notification permission the moment the user opts in.
        settings.$notifyFavorites
            .dropFirst()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.notifications.requestAuthorizationIfNeeded() }
            .store(in: &cancellables)
    }

    private var enabledLeagues: [SupportedLeague] {
        LeagueCatalog.all.filter { settings.enabledLeagues.contains($0.id) }
    }

    private var adapters: [SportAdapter] {
        enabledLeagues.map { $0.makeAdapter(favorites(for: $0.league)) }
    }

    /// Favorites passed to a league's adapter: exact team selections for team sports, plus the
    /// free-form tokens (which also cover golf/NASCAR players and drivers).
    private func favorites(for league: LeagueID) -> Set<String> {
        switch league.sport {
        case "golf", "racing":
            return settings.favoriteTokens
        default:
            return (settings.teamFavorites[league.league] ?? []).union(settings.favoriteTokens)
        }
    }

    // MARK: - Polling

    /// (Re)start the polling loop. Each iteration fetches, then sleeps for an adaptive
    /// interval chosen from what's currently live (spec §7). First iteration fetches at once.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.currentInterval ?? .seconds(60)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        var collected: [SportEvent] = []
        for adapter in adapters {
            do { collected += try await adapter.fetch(using: client) }
            catch { continue }  // one sport failing must never take down the others
        }
        lastRanked = collected.sorted { $0.sortPriority > $1.sortPriority }
        notifications.process(events: lastRanked, enabled: settings.notifyFavorites)
        await updateFavoritesWindow()
        applyDisplay()
    }

    // MARK: - Favorites window (±24h)

    /// Rebuild the ±24h favorites digest from cached adjacent-day games + today's favorites:
    /// recent finals (last 24h), live, and upcoming (next 24h), sorted chronologically.
    private func updateFavoritesWindow() async {
        await refreshAdjacentIfStale()
        favoritesDigest = Self.windowedFavorites(
            from: adjacentFavorites + lastRanked.filter(\.isFavorite), now: Date())
    }

    /// Keep favorite events within ±`horizon` of `now` (live games always kept), deduped by id
    /// and sorted chronologically. Pure — the seam the tests exercise.
    nonisolated static func windowedFavorites(
        from events: [SportEvent], now: Date, horizon: TimeInterval = 24 * 3600
    ) -> [SportEvent] {
        var seen = Set<String>()
        return events
            .filter { event in
                guard seen.insert(event.id).inserted else { return false }
                if event.isLive { return true }
                guard let date = event.date else { return false }
                return abs(date.timeIntervalSince(now)) <= horizon
            }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// Fetch yesterday + tomorrow for leagues that have favorites — cached on a 15-minute
    /// throttle since finals and schedules don't change. Team sports only (golf/NASCAR
    /// favorites are individuals, with no recent/upcoming "matchup" to window).
    private func refreshAdjacentIfStale() async {
        let now = Date()
        if let at = adjacentFetchedAt, now.timeIntervalSince(at) < 900 { return }
        adjacentFetchedAt = now
        let yesterday = Self.dayFormatter.string(from: now.addingTimeInterval(-86_400))
        let tomorrow = Self.dayFormatter.string(from: now.addingTimeInterval(86_400))

        var collected: [SportEvent] = []
        for supported in enabledLeagues
        where supported.league.sport != "golf" && supported.league.sport != "racing" {
            let favs = favorites(for: supported.league)
            guard !favs.isEmpty else { continue }
            let adapter = supported.makeAdapter(favs)
            for day in [yesterday, tomorrow] {
                if let events = try? await adapter.fetch(using: client, dates: day) {
                    collected += events.filter(\.isFavorite)
                }
            }
        }
        adjacentFavorites = collected
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// Derive what's shown from `lastRanked`: apply the favorites-only filter, recompute the
    /// cycle set and poll cadence, and refresh the menu-bar string. Cheap — no network.
    private func applyDisplay() {
        let shown = Self.displaySet(from: lastRanked,
                                    favoritesOnly: settings.favoritesOnly,
                                    hasFavorites: settings.hasAnyFavorites)
        events = shown
        currentInterval = pollInterval(for: shown)
        cycleCandidates = rotationCandidates(from: shown)
        cycleIndex = cycleCandidates.isEmpty ? 0 : cycleIndex % cycleCandidates.count
        updateMenuBar()
    }

    private func rotationCandidates(from shown: [SportEvent]) -> [SportEvent] {
        Self.rotationSet(
            live: shown.filter(\.isLive),
            windowNonLive: favoritesDigest.filter { !$0.isLive },
            includeFinished: settings.cycleFinished,
            includeUpcoming: settings.cycleUpcoming,
            fallback: shown)
    }

    /// The rotation set: live games always, plus the favorites window's recent finals and/or
    /// upcoming games per the two switches. Falls back to the single top event when nothing's
    /// live and neither switch contributes. Pure — the seam the tests exercise.
    nonisolated static func rotationSet(
        live: [SportEvent], windowNonLive: [SportEvent],
        includeFinished: Bool, includeUpcoming: Bool, fallback: [SportEvent]
    ) -> [SportEvent] {
        var result = live
        var seen = Set(result.map(\.id))
        for event in windowNonLive {
            let include = event.isFinal ? includeFinished : includeUpcoming
            if include, seen.insert(event.id).inserted { result.append(event) }
        }
        return result.isEmpty ? Array(fallback.prefix(1)) : result
    }

    // MARK: - Pinning

    func isPinned(_ id: String) -> Bool { settings.pinnedEventID == id }

    /// Pin a game to the menu bar (overriding rotation), or unpin if it's already pinned.
    func togglePin(_ id: String) {
        settings.pinnedEventID = (settings.pinnedEventID == id) ? nil : id
    }

    /// Adaptive cadence (spec §7): tight while a favorite is live, moderate for any live
    /// game, slow when nothing is live. `refreshSeconds` is the user's live-cadence knob.
    private func pollInterval(for events: [SportEvent]) -> Duration {
        if events.contains(where: { $0.isLive && $0.isFavorite }) {
            return .seconds(max(5, min(10, settings.refreshSeconds)))
        }
        if events.contains(where: \.isLive) {
            return .seconds(max(5, settings.refreshSeconds))
        }
        return idleInterval
    }

    // MARK: - Cycling display

    private func startCycling() {
        cycleTask?.cancel()
        let period = cyclePeriod
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: period)
                self?.advanceCycle()
            }
        }
    }

    private func advanceCycle() {
        guard settings.pinnedEventID == nil, cycleCandidates.count > 1 else { return }
        cycleIndex = (cycleIndex + 1) % cycleCandidates.count
        updateMenuBar()
    }

    private func updateMenuBar() {
        currentAwayLogo = nil
        currentHomeLogo = nil
        currentMatchup = nil
        if enabledLeagues.isEmpty {
            menuBarText = "No sports enabled"
            menuBarSymbol = "sportscourt.fill"
        } else {
            let pinned = settings.pinnedEventID.flatMap { id in
                (lastRanked + favoritesDigest).first { $0.id == id }
            }
            let chosen: SportEvent?
            if let pinned {
                chosen = pinned
            } else if cycleCandidates.count > 1 {
                chosen = cycleCandidates[cycleIndex % cycleCandidates.count]
            } else {
                chosen = cycleCandidates.first ?? events.first
            }
            if let chosen {
                menuBarText = truncate(chosen.displayString)
                menuBarSymbol = chosen.league.symbolName
                currentAwayLogo = chosen.awayLogo
                currentHomeLogo = chosen.homeLogo
                currentMatchup = chosen.matchup
            } else {
                menuBarSymbol = "sportscourt.fill"
                menuBarText = (settings.favoritesOnly && settings.hasAnyFavorites)
                    ? "No favorite games" : "No games"
            }
        }
        renderMenuBarImage()
    }

    /// Composite the menu-bar label into a single `NSImage`, because the status item won't
    /// render an icon and text together from a SwiftUI label. With team logos enabled and both
    /// logos cached, shows the matchup's color logos; otherwise the monochrome league glyph
    /// (a template image that adapts to the menu bar's light/dark appearance).
    private func renderMenuBarImage() {
        let awayImage = settings.showTeamLogos ? logos.image(for: currentAwayLogo) : nil
        let homeImage = settings.showTeamLogos ? logos.image(for: currentHomeLogo) : nil

        let label: AnyView
        let isTemplate: Bool
        if let awayImage, let homeImage, let matchup = currentMatchup {
            // [league glyph] [away logo] AWAY a - h HOME [home logo] · detail
            // ("AWAY vs HOME" for upcoming games, which have no score yet).
            let score = matchup.awayScore.isEmpty
                ? "\(matchup.away) vs \(matchup.home)"
                : "\(matchup.away) \(matchup.awayScore) - \(matchup.homeScore) \(matchup.home)"
            // Color logos force a non-template image, so the glyph + text won't auto-adapt —
            // resolve `.primary` against the current menu-bar appearance instead.
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            label = AnyView(
                HStack(spacing: 4) {
                    Image(systemName: menuBarSymbol)
                    Image(nsImage: awayImage).resizable().scaledToFit().frame(width: 15, height: 15)
                    Text(score)
                    Image(nsImage: homeImage).resizable().scaledToFit().frame(width: 15, height: 15)
                    if !matchup.detail.isEmpty { Text("· \(matchup.detail)") }
                }
                .font(.system(size: 13))
                .environment(\.colorScheme, dark ? .dark : .light)
            )
            isTemplate = false  // logos keep their colors
        } else {
            label = AnyView(
                HStack(spacing: 4) {
                    Image(systemName: menuBarSymbol)
                    Text(menuBarText)
                }.font(.system(size: 13))
            )
            isTemplate = true  // monochrome glyph adapts to light/dark
        }

        let renderer = ImageRenderer(content: label)
        renderer.scale = 2  // render @2x for crisp text on Retina
        guard let image = renderer.nsImage else { return }
        image.isTemplate = isTemplate
        menuBarImage = image
    }

    private func truncate(_ string: String) -> String {
        Self.truncate(string, limit: settings.maxLength)
    }

    /// Hard character cap with an ellipsis. The limit is floored at 8 so the result is never
    /// uselessly short. Pure (no actor state) so the formatting tests can call it directly.
    nonisolated static func truncate(_ string: String, limit: Int) -> String {
        let limit = max(8, limit)
        guard string.count > limit else { return string }
        return String(string.prefix(limit - 1)) + "…"
    }

    /// What the menu shows: when "favorites only" is on AND the user actually has favorites
    /// configured (structured team picks or free-form tokens), filter to favorite events;
    /// otherwise show everything (so it never filters down to nothing).
    nonisolated static func displaySet(
        from ranked: [SportEvent], favoritesOnly: Bool, hasFavorites: Bool
    ) -> [SportEvent] {
        (favoritesOnly && hasFavorites) ? ranked.filter(\.isFavorite) : ranked
    }

    /// Events worth cycling through: all live games, else favorites, else just the top one.
    nonisolated static func candidates(from ranked: [SportEvent]) -> [SportEvent] {
        let live = ranked.filter { if case .live = $0.state { return true } else { return false } }
        if !live.isEmpty { return live }
        let favorites = ranked.filter(\.isFavorite)
        return favorites.isEmpty ? Array(ranked.prefix(1)) : favorites
    }
}
