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
    /// Poll cadence in seconds.
    @Published var refreshSeconds: Int
    /// Hard character limit for the menu-bar string.
    @Published var maxLength: Int
    /// Rotate through multiple relevant events instead of showing only the top one.
    @Published var cycleEnabled: Bool

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    private enum Key {
        static let enabledLeagues = "enabledLeagues"
        static let favorites = "favorites"
        static let refreshSeconds = "refreshSeconds"
        static let maxLength = "maxLength"
        static let cycleEnabled = "cycleEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedLeagues = defaults.array(forKey: Key.enabledLeagues) as? [String]
        enabledLeagues = Set(storedLeagues ?? LeagueCatalog.all.map(\.id))
        favorites = defaults.string(forKey: Key.favorites) ?? ""
        refreshSeconds = defaults.object(forKey: Key.refreshSeconds) as? Int ?? 30
        maxLength = defaults.object(forKey: Key.maxLength) as? Int ?? 40
        cycleEnabled = defaults.object(forKey: Key.cycleEnabled) as? Bool ?? true

        persist($enabledLeagues) { [weak self] in self?.defaults.set(Array($0), forKey: Key.enabledLeagues) }
        persist($favorites) { [weak self] in self?.defaults.set($0, forKey: Key.favorites) }
        persist($refreshSeconds) { [weak self] in self?.defaults.set($0, forKey: Key.refreshSeconds) }
        persist($maxLength) { [weak self] in self?.defaults.set($0, forKey: Key.maxLength) }
        persist($cycleEnabled) { [weak self] in self?.defaults.set($0, forKey: Key.cycleEnabled) }
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
