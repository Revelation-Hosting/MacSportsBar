import SwiftUI
import Combine

/// Owns the polling loop, the ranked event list, and the cycling/truncation logic that
/// decides the single string shown in the menu bar. Reads everything user-tunable from the
/// shared `Settings` and reacts live as the user changes them.
@MainActor
final class AppModel: ObservableObject {
    /// The single string rendered in the menu bar.
    @Published var menuBarText: String = "Loading…"
    /// Full ranked list, surfaced in the dropdown menu.
    @Published var events: [SportEvent] = []

    private let client = ESPNClient()
    private let settings: Settings
    private var cancellables = Set<AnyCancellable>()

    private var pollTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var cycleIndex = 0
    private var cycleCandidates: [SportEvent] = []

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

        // Display-only changes → just re-render the current data.
        let displayChanges: [AnyPublisher<Void, Never>] = [
            settings.$maxLength.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$cycleEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(displayChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateMenuBar() }
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
        let ranked = collected.sorted { $0.sortPriority > $1.sortPriority }
        events = ranked
        currentInterval = pollInterval(for: ranked)
        cycleCandidates = Self.candidates(from: ranked)
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
        guard !enabledLeagues.isEmpty else {
            menuBarText = "No sports enabled"
            return
        }
        let chosen: SportEvent?
        if settings.cycleEnabled, cycleCandidates.count > 1 {
            chosen = cycleCandidates[cycleIndex % cycleCandidates.count]
        } else {
            chosen = events.first
        }
        menuBarText = chosen.map { truncate($0.displayString) } ?? "No games"
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
