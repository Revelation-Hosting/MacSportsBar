import XCTest
@testable import MacSportsBar

/// Tests for `Settings.favoriteTokens`, the comma/newline parser that turns the raw
/// favorites text field into normalized matching tokens.
final class SettingsTests: XCTestCase {

    /// A `Settings` backed by a throwaway, empty `UserDefaults` suite so tests never read or
    /// write the real app preferences.
    private func makeSettings() -> Settings {
        let suiteName = "MacSportsBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Settings(defaults: defaults)
    }

    func testTokensAreSplitTrimmedLowercasedAndDeduped() {
        let settings = makeSettings()
        settings.favorites = "Knicks, Lakers\n  Spurs  ,,  ,celtics, knicks"
        XCTAssertEqual(settings.favoriteTokens, ["knicks", "lakers", "spurs", "celtics"])
    }

    func testCommaAndNewlineAreBothSeparators() {
        let settings = makeSettings()
        settings.favorites = "NY\nSA,DAL"
        XCTAssertEqual(settings.favoriteTokens, ["ny", "sa", "dal"])
    }

    func testEmptyStringYieldsNoTokens() {
        let settings = makeSettings()
        settings.favorites = ""
        XCTAssertTrue(settings.favoriteTokens.isEmpty)
    }

    func testSeparatorsAndWhitespaceOnlyYieldNoTokens() {
        let settings = makeSettings()
        settings.favorites = " , , \n ,, "
        XCTAssertTrue(settings.favoriteTokens.isEmpty)
    }
}
