import Foundation
import Combine

/// User-tunable settings, persisted in `UserDefaults` and shared between the menu-bar
/// model and the settings window. (The spec calls for `@AppStorage`; a shared
/// `ObservableObject` over the same `UserDefaults` is the multi-owner equivalent.)
final class Settings: ObservableObject {
    static let shared = Settings()

    /// League slugs that are switched on.
    @Published var enabledLeagues: Set<String>
    /// Comma-separated favorite team names/abbreviations, matched case-insensitively.
    @Published var favorites: String
    /// Poll cadence in seconds while games are live. (Idle polling slows automatically — see
    /// `AppModel.pollInterval`.)
    @Published var refreshSeconds: Int
    /// Hard character limit for the menu-bar string.
    @Published var maxLength: Int
    /// Rotate through multiple relevant events instead of showing only the top one.
    @Published var cycleEnabled: Bool
    /// When on (and favorites are set), the ticker shows only favorite teams' games.
    @Published var favoritesOnly: Bool
    /// Notify on boundary events (new period/inning/half + final) for favorite teams.
    @Published var notifyFavorites: Bool
    /// Per-league favorite team abbreviations (lowercased), chosen in the team picker.
    /// Exact matches — no fuzzy substring matching like the free-form `favorites` field.
    @Published var teamFavorites: [String: Set<String>]

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    private enum Key {
        static let enabledLeagues = "enabledLeagues"
        static let seenLeagues = "seenLeagues"
        static let favorites = "favorites"
        static let refreshSeconds = "refreshSeconds"
        static let maxLength = "maxLength"
        static let cycleEnabled = "cycleEnabled"
        static let favoritesOnly = "favoritesOnly"
        static let notifyFavorites = "notifyFavorites"
        static let teamFavorites = "teamFavorites"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let allLeagueIDs = LeagueCatalog.all.map(\.id)
        if let storedLeagues = defaults.array(forKey: Key.enabledLeagues) as? [String] {
            // Returning user: auto-enable leagues added since they last ran (so new sports
            // appear without a manual toggle), but never re-enable one they've turned off.
            let seen = Set(defaults.array(forKey: Key.seenLeagues) as? [String] ?? [])
            var enabled = Set(storedLeagues)
            enabled.formUnion(allLeagueIDs.filter { !seen.contains($0) })
            enabledLeagues = enabled
            defaults.set(Array(enabled), forKey: Key.enabledLeagues)
        } else {
            // First run: everything on.
            enabledLeagues = Set(allLeagueIDs)
        }
        defaults.set(allLeagueIDs, forKey: Key.seenLeagues)
        favorites = defaults.string(forKey: Key.favorites) ?? ""
        refreshSeconds = defaults.object(forKey: Key.refreshSeconds) as? Int ?? 30
        maxLength = defaults.object(forKey: Key.maxLength) as? Int ?? 40
        cycleEnabled = defaults.object(forKey: Key.cycleEnabled) as? Bool ?? true
        favoritesOnly = defaults.object(forKey: Key.favoritesOnly) as? Bool ?? false
        notifyFavorites = defaults.object(forKey: Key.notifyFavorites) as? Bool ?? false
        if let data = defaults.data(forKey: Key.teamFavorites),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            teamFavorites = decoded.mapValues { Set($0) }
        } else {
            teamFavorites = [:]
        }

        persist($enabledLeagues) { [weak self] in self?.defaults.set(Array($0), forKey: Key.enabledLeagues) }
        persist($favorites) { [weak self] in self?.defaults.set($0, forKey: Key.favorites) }
        persist($refreshSeconds) { [weak self] in self?.defaults.set($0, forKey: Key.refreshSeconds) }
        persist($maxLength) { [weak self] in self?.defaults.set($0, forKey: Key.maxLength) }
        persist($cycleEnabled) { [weak self] in self?.defaults.set($0, forKey: Key.cycleEnabled) }
        persist($favoritesOnly) { [weak self] in self?.defaults.set($0, forKey: Key.favoritesOnly) }
        persist($notifyFavorites) { [weak self] in self?.defaults.set($0, forKey: Key.notifyFavorites) }
        persist($teamFavorites) { [weak self] favorites in
            let encodable = favorites.mapValues { Array($0) }
            self?.defaults.set(try? JSONEncoder().encode(encodable), forKey: Key.teamFavorites)
        }
    }

    /// Whether `abbreviation` is a favorite within `league` (slug).
    func isFavoriteTeam(_ abbreviation: String, in league: String) -> Bool {
        teamFavorites[league]?.contains(abbreviation.lowercased()) ?? false
    }

    /// Toggle a team's favorite status within a league.
    func setFavoriteTeam(_ abbreviation: String, in league: String, on: Bool) {
        var set = teamFavorites[league] ?? []
        if on { set.insert(abbreviation.lowercased()) } else { set.remove(abbreviation.lowercased()) }
        teamFavorites[league] = set.isEmpty ? nil : set
    }

    /// Parsed, lowercased favorite tokens used for matching against feed names.
    var favoriteTokens: Set<String> {
        Set(
            favorites
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// Write a property back to `UserDefaults` whenever it changes (skipping the initial value).
    private func persist<T>(_ publisher: Published<T>.Publisher, _ write: @escaping (T) -> Void) {
        publisher.dropFirst().sink(receiveValue: write).store(in: &cancellables)
    }
}
