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

    private let client = ESPNClient()
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()

    private var pollTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var cycleIndex = 0
    private var cycleCandidates: [SportEvent] = []
    /// Latest fetched + ranked events, before the favorites-only display filter is applied.
    private var lastRanked: [SportEvent] = []

    /// How fast the menu bar rotates when several events are relevant at once.
    private let cyclePeriod: Duration = .seconds(8)

    /// Poll cadence when nothing relevant is live (spec §7 idle tier).
    private let idleInterval: Duration = .seconds(300)
    /// Cadence chosen after the last fetch, based on what's currently live.
    private var currentInterval: Duration = .seconds(30)

    init(settings: Settings = .shared) {
        self.settings = settings
        observeSettings()
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
        ]
        Publishers.MergeMany(dataChanges)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.startPolling() }
            .store(in: &cancellables)

        // Display-only changes → re-derive the shown set from the last fetch (no refetch).
        let displayChanges: [AnyPublisher<Void, Never>] = [
            settings.$maxLength.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$cycleEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$favoritesOnly.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(displayChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyDisplay() }
            .store(in: &cancellables)
    }

    private var enabledLeagues: [SupportedLeague] {
        LeagueCatalog.all.filter { settings.enabledLeagues.contains($0.id) }
    }

    private var adapters: [SportAdapter] {
        let tokens = settings.favoriteTokens
        return enabledLeagues.map { $0.makeAdapter(tokens) }
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
        applyDisplay()
    }

    /// Derive what's shown from `lastRanked`: apply the favorites-only filter, recompute the
    /// cycle set and poll cadence, and refresh the menu-bar string. Cheap — no network.
    private func applyDisplay() {
        let shown = (settings.favoritesOnly && !settings.favoriteTokens.isEmpty)
            ? lastRanked.filter(\.isFavorite)
            : lastRanked
        events = shown
        currentInterval = pollInterval(for: shown)
        cycleCandidates = Self.candidates(from: shown)
        cycleIndex = cycleCandidates.isEmpty ? 0 : cycleIndex % cycleCandidates.count
        updateMenuBar()
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
        guard settings.cycleEnabled, cycleCandidates.count > 1 else { return }
        cycleIndex = (cycleIndex + 1) % cycleCandidates.count
        updateMenuBar()
    }

    private func updateMenuBar() {
        if enabledLeagues.isEmpty {
            menuBarText = "No sports enabled"
            menuBarSymbol = "sportscourt.fill"
        } else {
            let chosen: SportEvent?
            if settings.cycleEnabled, cycleCandidates.count > 1 {
                chosen = cycleCandidates[cycleIndex % cycleCandidates.count]
            } else {
                chosen = events.first
            }
            if let chosen {
                menuBarText = truncate(chosen.displayString)
                menuBarSymbol = chosen.league.symbolName
            } else {
                menuBarSymbol = "sportscourt.fill"
                menuBarText = (settings.favoritesOnly && !settings.favoriteTokens.isEmpty)
                    ? "No favorite games" : "No games"
            }
        }
        renderMenuBarImage()
    }

    /// Composite the league glyph and the score into a single template `NSImage`, because the
    /// status item won't render an icon and text together from a SwiftUI label.
    private func renderMenuBarImage() {
        let label = HStack(spacing: 4) {
            Image(systemName: menuBarSymbol)
            Text(menuBarText)
        }
        .font(.system(size: 13))

        let renderer = ImageRenderer(content: label)
        renderer.scale = 2  // render @2x for crisp text on Retina
        guard let image = renderer.nsImage else { return }
        image.isTemplate = true  // adapt to the menu bar's light/dark appearance
        menuBarImage = image
    }

    private func truncate(_ string: String) -> String {
        let limit = max(8, settings.maxLength)
        guard string.count > limit else { return string }
        return String(string.prefix(limit - 1)) + "…"
    }

    /// Events worth cycling through: all live games, else favorites, else just the top one.
    private static func candidates(from ranked: [SportEvent]) -> [SportEvent] {
        let live = ranked.filter { if case .live = $0.state { return true } else { return false } }
        if !live.isEmpty { return live }
        let favorites = ranked.filter(\.isFavorite)
        return favorites.isEmpty ? Array(ranked.prefix(1)) : favorites
    }
}
