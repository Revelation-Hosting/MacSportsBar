import SwiftUI
import Combine
import AppKit

/// Owns the polling loop, the ranked event list, and the cycling/truncation logic that
/// decides the single string shown in the menu bar. Reads everything user-tunable from the
/// shared `Settings` and reacts live as the user changes them.
/// The composited menu-bar image, in its *own* observable so the `MenuBarExtra` label observes
/// only this — not the whole `AppModel`. `AppModel.events`/`favoritesDigest` are reassigned every
/// poll; if the label observed them it would be re-pushed to the status item every few seconds
/// (and macOS drops the item on that churn). This updates only when the image truly changes.
@MainActor
final class MenuBarPresenter: ObservableObject {
    @Published var image: NSImage?
}

@MainActor
final class AppModel: ObservableObject {
    /// The composited menu-bar image lives here (not on `AppModel`) so the label doesn't re-render
    /// on unrelated poll churn — see `MenuBarPresenter`.
    let menuBar = MenuBarPresenter()
    /// Internal render inputs (not observed by any view; the label reads `menuBar.image`).
    private(set) var menuBarText: String = "Loading…"
    private(set) var menuBarSymbol: String = "sportscourt.fill"
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
    /// Logo URLs + per-team breakdown of the currently-displayed matchup, for the interleaved
    /// menu-bar team-logos layout.
    private var currentAwayLogo: URL?
    private var currentHomeLogo: URL?
    private var currentMatchup: SportEvent.Matchup?
    /// Current event's racing flag, when it's a live NASCAR race — drives a colored flag glyph.
    private var currentFlag: RaceFlag?
    /// Signature of the last *successfully* rendered menu-bar image. Polls (every 5–10s) and the
    /// cycle tick re-render even when the readout is identical; re-poking the `MenuBarExtra` label
    /// that often makes it flicker/blank, so we skip when nothing visible changed.
    private var lastRenderSignature: String?
    /// The menu bar's *own* light/dark appearance, fed from the status item by the SwiftUI
    /// label (which is hosted in the menu bar, so it knows the real, wallpaper-driven tint —
    /// unlike the app's appearance or the global Dark Mode setting, which both guessed wrong).
    /// We color the interleaved (non-template) image's glyph + text to match it.
    var menuBarColorScheme: ColorScheme = .light {
        didSet { if menuBarColorScheme != oldValue { renderMenuBarImage() } }
    }

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
            settings.$followedLeagues.dropFirst().map { _ in () }.eraseToAnyPublisher(),
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
        let marked = Self.applyFollowedLeagues(collected, followed: settings.followedLeagues)
        lastRanked = marked.sorted { $0.sortPriority > $1.sortPriority }
        notifications.process(
            events: lastRanked, enabled: settings.notifyFavorites,
            prefs: .init(start: settings.notifyStart, period: settings.notifyPeriod, final: settings.notifyFinal))
        await updateFavoritesWindow()
        applyDisplay()
    }

    /// Promote events from a followed series to favorites. Golf and NASCAR have no team to
    /// pick, so the user follows the whole tour/series; doing this here (rather than per-driver
    /// in the adapter) makes every race/tournament in that league count as a favorite — so it
    /// survives the favorites-only filter and joins the ±24h digest. Pure — a tested seam.
    nonisolated static func applyFollowedLeagues(
        _ events: [SportEvent], followed: Set<String>
    ) -> [SportEvent] {
        guard !followed.isEmpty else { return events }
        return events.map { event in
            guard !event.isFavorite, followed.contains(event.league.league) else { return event }
            var promoted = event
            promoted.isFavorite = true
            return promoted
        }
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
        // Drop stale finals first: an idle/off-season league's scoreboard keeps returning its
        // last game forever (ESPN served a 3-week-old NBA Finals final all summer), so a final
        // older than the ±24h window shouldn't linger in the ticker or the dropdown.
        let fresh = Self.freshDisplayEvents(lastRanked, now: Date())
        let shown = Self.displaySet(from: fresh,
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

    /// Adaptive cadence (spec §7): tight while a favorite is live, moderate for any live game,
    /// slow when nothing is live — but ramping up as a favorite's *scheduled* start approaches,
    /// so we catch tip-off (and fire the "Starting" alert) promptly instead of on the slow idle
    /// tick. `refreshSeconds` is the user's live-cadence knob.
    private func pollInterval(for events: [SportEvent]) -> Duration {
        if events.contains(where: { $0.isLive && $0.isFavorite }) {
            return .seconds(max(5, min(10, settings.refreshSeconds)))
        }
        if events.contains(where: \.isLive) {
            return .seconds(max(5, settings.refreshSeconds))
        }
        if let untilStart = Self.nextFavoriteStart(in: events, now: Date()) {
            return Self.startupRampInterval(secondsUntilStart: untilStart)
        }
        return idleInterval
    }

    /// Seconds until the soonest favorite game's scheduled start (negative if already due),
    /// ignoring games more than 30 min overdue but still "pre" (likely postponed or a stale
    /// feed — don't poll-storm forever). Nil if no favorite is upcoming. Pure — a tested seam.
    nonisolated static func nextFavoriteStart(in events: [SportEvent], now: Date) -> TimeInterval? {
        events
            .compactMap { event -> TimeInterval? in
                guard event.isFavorite, case .pre = event.state, let date = event.date
                else { return nil }
                return date.timeIntervalSince(now)
            }
            .filter { $0 > -1800 }
            .min()
    }

    /// Poll cadence as a favorite's start nears: tight when it's imminent or just-overdue so we
    /// catch the tip-off, a check-a-minute within ~15 min, idle when it's further out. Pure — a
    /// tested seam.
    nonisolated static func startupRampInterval(secondsUntilStart: TimeInterval) -> Duration {
        switch secondsUntilStart {
        case ..<120:  return .seconds(20)    // imminent or just-overdue → catch it within ~20s
        case ..<900:  return .seconds(60)    // within 15 min → check each minute
        default:      return .seconds(300)   // further out → idle
        }
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
        currentFlag = nil
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
                menuBarText = Self.fitMenuBar(full: Self.barText(for: chosen),
                                              short: chosen.menuShort, limit: settings.maxLength)
                menuBarSymbol = chosen.league.symbolName
                currentAwayLogo = chosen.awayLogo
                currentHomeLogo = chosen.homeLogo
                currentMatchup = chosen.matchup
                currentFlag = chosen.flag
            } else {
                menuBarSymbol = "sportscourt.fill"
                menuBarText = (settings.favoritesOnly && settings.hasAnyFavorites)
                    ? "No favorite games" : "No games"
            }
        }
        renderMenuBarImage()
    }

    /// Composite the menu-bar label into a single `NSImage`, because the status item won't
    /// render an icon and text together from a SwiftUI label.
    ///
    /// Every sport renders the *same* way: one flat (non-template) image whose glyph + text are
    /// tinted to `menuBarColorScheme` — the menu bar's own light/dark appearance, which the
    /// SwiftUI label feeds us from the status item itself (the only source that tracks the real,
    /// wallpaper-driven tint; this is the dark-mode fix). Color team logos and the NASCAR flag
    /// keep their own hue. We deliberately forgo the system's *template* vibrancy so a readout
    /// with a color icon (logos/flag) and one without (golf, plain scores) look identically bold,
    /// instead of the color ones rendering brighter than the template ones.
    private func renderMenuBarImage() {
        let awayImage = settings.showTeamLogos ? logos.image(for: currentAwayLogo) : nil
        let homeImage = settings.showTeamLogos ? logos.image(for: currentHomeLogo) : nil

        // Skip when the visible output would be identical to the last render — avoids re-poking
        // the menu bar (and the flicker that causes) on every poll/cycle tick. Captures every
        // input that affects the pixels: text, glyph, flag, tint, and the logo/matchup state.
        let signature = [
            menuBarText, menuBarSymbol, "\(menuBarColorScheme)",
            currentFlag.map { "\($0)" } ?? "-",
            awayImage != nil ? (currentAwayLogo?.absoluteString ?? "a") : "-",
            homeImage != nil ? (currentHomeLogo?.absoluteString ?? "h") : "-",
            currentMatchup.map { "\($0.away) \($0.awayScore) \($0.home) \($0.homeScore) \($0.detail)" } ?? "-",
        ].joined(separator: "|")
        if signature == lastRenderSignature { return }

        let content: AnyView
        if let awayImage, let homeImage, let matchup = currentMatchup {
            // [league glyph] [away logo] AWAY a - h HOME [home logo] · detail
            // ("AWAY vs HOME" for upcoming games, which have no score yet).
            let score = matchup.awayScore.isEmpty
                ? "\(matchup.away) vs \(matchup.home)"
                : "\(matchup.away) \(matchup.awayScore) - \(matchup.homeScore) \(matchup.home)"
            content = AnyView(
                HStack(spacing: 4) {
                    Image(systemName: menuBarSymbol)
                    Image(nsImage: awayImage).resizable().scaledToFit().frame(width: 15, height: 15)
                    Text(score)
                    Image(nsImage: homeImage).resizable().scaledToFit().frame(width: 15, height: 15)
                    if !matchup.detail.isEmpty { Text("· \(matchup.detail)") }
                }
            )
        } else if let flag = currentFlag {
            // Live NASCAR: a *colored* flag glyph (green/yellow/red) keeps its hue; checkered/pace
            // and the text tint with the menu bar below.
            let (symbol, color) = Self.flagGlyph(flag)
            content = AnyView(
                HStack(spacing: 4) {
                    if let color { Image(systemName: symbol).foregroundStyle(color) }
                    else { Image(systemName: symbol) }
                    Text(menuBarText)
                }
            )
        } else {
            content = AnyView(
                HStack(spacing: 4) {
                    Image(systemName: menuBarSymbol)
                    Text(menuBarText)
                }
            )
        }

        // One uniform treatment for all three: flat, tinted to the menu bar's own appearance.
        let label = content
            .font(.system(size: 13))
            .foregroundStyle(menuBarColorScheme == .dark ? Color.white : Color.black)
            .environment(\.colorScheme, menuBarColorScheme)

        let renderer = ImageRenderer(content: label)
        renderer.scale = 2  // render @2x for crisp text on Retina
        // Never assign an empty image — ImageRenderer occasionally returns nil or a zero-size
        // bitmap, which would blank the menu-bar item. Keep the last good one and retry next tick.
        guard let image = renderer.nsImage, image.size.width > 1, image.size.height > 1 else { return }
        image.isTemplate = false  // uniform flat look across every sport
        menuBar.image = image
        lastRenderSignature = signature
    }

    /// SF Symbol + color for a racing flag. A non-nil color paints the flag (green/yellow/red);
    /// nil means "tint with the menu-bar text color" (checkered finish, and pace laps, which
    /// have no distinct hue). Checkered uses the checkered-flag symbol; the rest a filled flag.
    nonisolated static func flagGlyph(_ flag: RaceFlag) -> (symbol: String, color: Color?) {
        switch flag {
        case .green:     return ("flag.fill", .green)
        case .caution:   return ("flag.fill", .yellow)
        case .red:       return ("flag.fill", .red)
        case .checkered: return ("flag.checkered", nil)
        case .warmup:    return ("flag.fill", nil)
        }
    }

    /// The interleaved menu-bar readout for an event: `AWAY a - h HOME · detail`
    /// (`AWAY vs HOME · detail` before tip-off) from the per-team matchup, else the event's own
    /// display string (golf/racing have no matchup). Pure — a formatting seam the tests cover.
    nonisolated static func barText(for event: SportEvent) -> String {
        guard let m = event.matchup else { return event.displayString }
        let core = m.awayScore.isEmpty
            ? "\(m.away) vs \(m.home)"
            : "\(m.away) \(m.awayScore) - \(m.homeScore) \(m.home)"
        return m.detail.isEmpty ? core : "\(core) · \(m.detail)"
    }

    /// Hard character cap with an ellipsis. The limit is floored at 8 so the result is never
    /// uselessly short. Pure (no actor state) so the formatting tests can call it directly.
    nonisolated static func truncate(_ string: String, limit: Int) -> String {
        let limit = max(8, limit)
        guard string.count > limit else { return string }
        return String(string.prefix(limit - 1)) + "…"
    }

    /// Pick the longest readout that fits the menu-bar width: the full string if it fits, else a
    /// compact fallback that drops the least-important context (the race name), else the compact
    /// string hard-clipped. So a wide bar shows everything and a tight one keeps the lap/leader
    /// instead of clipping them. Pure — a tested seam.
    nonisolated static func fitMenuBar(full: String, short: String?, limit: Int) -> String {
        let cap = max(8, limit)
        if full.count <= cap { return full }
        if let short, short.count <= cap { return short }
        return truncate(short ?? full, limit: limit)
    }

    /// Drop **stale finals** — a `final` whose date is older than `staleAfter` (default 24h).
    /// An idle/off-season league's scoreboard keeps returning its last game indefinitely, so
    /// without this a weeks-old final lingers in the ticker/dropdown. Live and upcoming events,
    /// recent finals, and events with no date are all kept. Pure — a tested seam.
    nonisolated static func freshDisplayEvents(
        _ events: [SportEvent], now: Date, staleAfter: TimeInterval = 24 * 3600
    ) -> [SportEvent] {
        events.filter { event in
            guard event.isFinal, let date = event.date else { return true }
            return now.timeIntervalSince(date) <= staleAfter
        }
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
