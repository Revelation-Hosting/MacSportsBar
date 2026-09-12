import XCTest
@testable import MacSportsBar

/// Regression tests for the favorites-only display filter. Originally a single global switch
/// whose guard only checked the free-form tokens (so structured picks left it inert); it's now
/// per league, so you can hide every soccer match but your club's while keeping the whole
/// NCAAF slate. These lock both the per-league scoping and the never-filter-to-nothing rule.
final class DisplayFilterTests: XCTestCase {

    private let league = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
    private let soccer = LeagueID(sport: "soccer", league: "eng.1", displayName: "Premier League")
    private func event(_ id: String, favorite: Bool, in league: LeagueID? = nil) -> SportEvent {
        SportEvent(id: id, league: league ?? self.league, state: .live, displayString: id,
                   isFavorite: favorite, sortPriority: 0)
    }

    func testFiltersToFavoritesInRestrictedLeague() {
        let events = [event("a", favorite: true), event("b", favorite: false), event("c", favorite: true)]
        let shown = AppModel.displaySet(from: events, favoritesOnlyLeagues: ["nba"])
        XCTAssertEqual(shown.map(\.id), ["a", "c"])
    }

    func testOnlyRestrictedLeaguesAreFiltered() {
        // Soccer restricted, NBA not: every NBA game stays, only the favorite soccer match does.
        let events = [
            event("nba-fav", favorite: true), event("nba-other", favorite: false),
            event("epl-fav", favorite: true, in: soccer), event("epl-other", favorite: false, in: soccer),
        ]
        let shown = AppModel.displaySet(from: events, favoritesOnlyLeagues: ["eng.1"])
        XCTAssertEqual(shown.map(\.id), ["nba-fav", "nba-other", "epl-fav"])
    }

    func testShowsEverythingWhenNoLeagueIsRestricted() {
        let events = [event("a", favorite: true), event("b", favorite: false)]
        let shown = AppModel.displaySet(from: events, favoritesOnlyLeagues: [])
        XCTAssertEqual(shown.map(\.id), ["a", "b"])
    }

    // MARK: - Settings side: which leagues are *actively* restricted

    private func freshSettings() -> Settings {
        let suite = "MacSportsBarTests.favOnly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Settings(defaults: defaults)
    }

    func testRestrictionIsInertUntilTheLeagueHasFavorites() {
        // Never filter a league down to nothing: "favorites only" with no favorites picked in
        // that league shows everything, and switches on the moment a favorite is picked.
        let settings = freshSettings()
        settings.setFavoritesOnly("eng.1", on: true)
        XCTAssertTrue(settings.isFavoritesOnly("eng.1"))
        XCTAssertFalse(settings.hasFavorites(in: "eng.1"))
        XCTAssertEqual(settings.activeFavoritesOnlyLeagues, [])

        settings.setFavoriteTeam("ARS", in: "eng.1", on: true)
        XCTAssertEqual(settings.activeFavoritesOnlyLeagues, ["eng.1"])

        settings.setFavoriteTeam("ARS", in: "eng.1", on: false)
        XCTAssertEqual(settings.activeFavoritesOnlyLeagues, [], "unpicking the last team relaxes it")
    }

    func testHasFavoritesInLeagueCountsFollowsAndFreeText() {
        let settings = freshSettings()
        XCTAssertFalse(settings.hasFavorites(in: "nascar-premier"))
        settings.setFollowingLeague("nascar-premier", on: true)
        XCTAssertTrue(settings.hasFavorites(in: "nascar-premier"), "a followed series counts")
        XCTAssertFalse(settings.hasFavorites(in: "nba"), "…but only for that league")

        settings.favorites = "Scheffler"
        XCTAssertTrue(settings.hasFavorites(in: "nba"), "free-form tokens apply to every league")
    }

    func testFavoritesOnlyLeaguesPersistAndPrune() {
        let suite = "MacSportsBarTests.favOnlyPersist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = Settings(defaults: defaults)
        first.setFavoritesOnly("nba", on: true)
        first.setFavoritesOnly("mlb", on: true)
        first.setFavoritesOnly("nba", on: false)
        XCTAssertEqual(Settings(defaults: defaults).favoritesOnlyLeagues, ["mlb"])
    }

    func testLegacyGlobalSwitchMigratesToEveryLeague() {
        // The old single "Show favorites only" toggle applied to all leagues — a user who had
        // it on should see the same behavior, now expressed per league.
        let suite = "MacSportsBarTests.favOnlyMigrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "favoritesOnly")
        let migrated = Settings(defaults: defaults)
        XCTAssertEqual(migrated.favoritesOnlyLeagues, Set(LeagueCatalog.all.map(\.id)))

        // Once the per-league set exists it wins, even over a lingering legacy flag.
        migrated.setFavoritesOnly("nba", on: false)
        XCTAssertEqual(Settings(defaults: defaults).favoritesOnlyLeagues,
                       Set(LeagueCatalog.all.map(\.id)).subtracting(["nba"]))
    }

    func testLegacySwitchOffMigratesToNothingRestricted() {
        let suite = "MacSportsBarTests.favOnlyMigrateOff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "favoritesOnly")
        XCTAssertEqual(Settings(defaults: defaults).favoritesOnlyLeagues, [])
    }

    // MARK: - Stale-final filter (idle/off-season leagues keep returning their last game)

    private func dated(_ id: String, _ state: SportEvent.State, date: Date?) -> SportEvent {
        SportEvent(id: id, league: league, state: state, displayString: id,
                   isFavorite: false, sortPriority: 0, date: date)
    }

    func testDropsFinalsOlderThan24h() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let events = [
            dated("old", .final, date: now.addingTimeInterval(-21 * 86_400)),  // 3 weeks → drop
            dated("recent", .final, date: now.addingTimeInterval(-3600)),       // 1h → keep
            dated("live", .live, date: now.addingTimeInterval(-9999)),          // live → keep
            dated("upcoming", .pre(startDate: nil), date: now.addingTimeInterval(7200)), // keep
            dated("nodate", .final, date: nil),                                 // no date → keep
        ]
        let fresh = AppModel.freshDisplayEvents(events, now: now).map(\.id)
        XCTAssertEqual(fresh, ["recent", "live", "upcoming", "nodate"])
        XCTAssertFalse(fresh.contains("old"), "a 3-week-old final must not linger")
    }

    func testHasAnyFavoritesCountsStructuredPicks() {
        let suite = "MacSportsBarTests.hasFav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults)

        XCTAssertFalse(settings.hasAnyFavorites)
        settings.setFavoriteTeam("SEA", in: "mlb", on: true)
        XCTAssertTrue(settings.hasAnyFavorites, "a structured pick counts")
        settings.setFavoriteTeam("SEA", in: "mlb", on: false)
        XCTAssertFalse(settings.hasAnyFavorites)
        settings.favorites = "Scheffler"
        XCTAssertTrue(settings.hasAnyFavorites, "free-form tokens count too")
    }
}
