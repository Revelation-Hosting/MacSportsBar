import XCTest
@testable import MacSportsBar

/// Regression tests for the per-league display filter. Originally a single global
/// "favorites only" switch whose guard only checked the free-form tokens (so structured picks
/// left it inert); it's now a per-league mode — all / Top 25 + favorites / favorites only — so
/// you can hide every soccer match but your club's while keeping the whole NCAAF slate. These
/// lock the per-league scoping, the tier semantics, and the never-filter-to-nothing rule.
final class DisplayFilterTests: XCTestCase {

    private let league = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
    private let soccer = LeagueID(sport: "soccer", league: "eng.1", displayName: "Premier League")
    private let ncaaf = LeagueID(sport: "football", league: "college-football", displayName: "NCAAF",
                                 hasRankings: true)
    private func event(_ id: String, favorite: Bool, ranked: Bool = false,
                       in league: LeagueID? = nil) -> SportEvent {
        SportEvent(id: id, league: league ?? self.league, state: .live, displayString: id,
                   isFavorite: favorite, sortPriority: 0, isRanked: ranked)
    }

    func testFavoritesOnlyKeepsJustFavoritesInThatLeague() {
        let events = [event("a", favorite: true), event("b", favorite: false), event("c", favorite: true)]
        let shown = AppModel.displaySet(from: events, filters: ["nba": .favorites])
        XCTAssertEqual(shown.map(\.id), ["a", "c"])
    }

    func testOnlyFilteredLeaguesAreTouched() {
        // Soccer restricted, NBA not: every NBA game stays, only the favorite soccer match does.
        let events = [
            event("nba-fav", favorite: true), event("nba-other", favorite: false),
            event("epl-fav", favorite: true, in: soccer), event("epl-other", favorite: false, in: soccer),
        ]
        let shown = AppModel.displaySet(from: events, filters: ["eng.1": .favorites])
        XCTAssertEqual(shown.map(\.id), ["nba-fav", "nba-other", "epl-fav"])
    }

    func testTop25KeepsRankedGamesAndFavorites() {
        // The middle tier: a Top-25 matchup stays, an unranked favorite stays, the rest go.
        let events = [
            event("ranked", favorite: false, ranked: true, in: ncaaf),
            event("unranked-fav", favorite: true, ranked: false, in: ncaaf),
            event("unranked", favorite: false, ranked: false, in: ncaaf),
        ]
        let shown = AppModel.displaySet(from: events, filters: ["college-football": .ranked])
        XCTAssertEqual(shown.map(\.id), ["ranked", "unranked-fav"])
    }

    func testFavoritesOnlyDropsRankedNonFavorites() {
        let events = [event("ranked", favorite: false, ranked: true, in: ncaaf),
                      event("fav", favorite: true, in: ncaaf)]
        let shown = AppModel.displaySet(from: events, filters: ["college-football": .favorites])
        XCTAssertEqual(shown.map(\.id), ["fav"])
    }

    func testShowsEverythingWithNoFilters() {
        let events = [event("a", favorite: true), event("b", favorite: false)]
        let shown = AppModel.displaySet(from: events, filters: [:])
        XCTAssertEqual(shown.map(\.id), ["a", "b"])
        XCTAssertEqual(AppModel.displaySet(from: events, filters: ["nba": .all]).map(\.id), ["a", "b"])
    }

    func testRankedOptionOnlyOfferedWhereTheFeedRanks() {
        XCTAssertEqual(LeagueFilter.options(for: ncaaf), [.all, .ranked, .favorites])
        XCTAssertEqual(LeagueFilter.options(for: league), [.all, .favorites])
        let catalogNCAAF = LeagueCatalog.all.first { $0.id == "college-football" }?.league
        XCTAssertTrue(catalogNCAAF?.hasRankings ?? false, "the catalog entry must opt in")
    }

    // MARK: - Settings side: which filters are *actively* in force

    private func freshSettings() -> Settings {
        let suite = "MacSportsBarTests.favOnly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Settings(defaults: defaults)
    }

    func testFavoritesOnlyIsInertUntilTheLeagueHasFavorites() {
        // Never filter a league down to nothing: "favorites only" with no favorites picked in
        // that league shows everything, and switches on the moment a favorite is picked.
        let settings = freshSettings()
        settings.setFilter(.favorites, for: "eng.1")
        XCTAssertEqual(settings.filter(for: "eng.1"), .favorites)
        XCTAssertFalse(settings.hasFavorites(in: "eng.1"))
        XCTAssertEqual(settings.activeFilters, [:])

        settings.setFavoriteTeam("ARS", in: "eng.1", on: true)
        XCTAssertEqual(settings.activeFilters, ["eng.1": .favorites])

        settings.setFavoriteTeam("ARS", in: "eng.1", on: false)
        XCTAssertEqual(settings.activeFilters, [:], "unpicking the last team relaxes it")
    }

    func testTop25DoesNotNeedFavorites() {
        let settings = freshSettings()
        settings.setFilter(.ranked, for: "college-football")
        XCTAssertEqual(settings.activeFilters, ["college-football": .ranked])
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

    func testFiltersPersistAndAllClearsTheEntry() {
        let suite = "MacSportsBarTests.favOnlyPersist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = Settings(defaults: defaults)
        first.setFilter(.favorites, for: "nba")
        first.setFilter(.ranked, for: "college-football")
        first.setFilter(.all, for: "nba")
        XCTAssertEqual(Settings(defaults: defaults).leagueFilters, ["college-football": .ranked])
    }

    func testLegacyGlobalSwitchMigratesToEveryLeague() {
        // The old single "Show favorites only" toggle applied to all leagues — a user who had
        // it on should see the same behavior, now expressed per league.
        let suite = "MacSportsBarTests.favOnlyMigrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "favoritesOnly")
        let migrated = Settings(defaults: defaults)
        let everyLeague = Dictionary(uniqueKeysWithValues: LeagueCatalog.all.map { ($0.id, LeagueFilter.favorites) })
        XCTAssertEqual(migrated.leagueFilters, everyLeague)

        // Once the per-league map exists it wins, even over a lingering legacy flag.
        migrated.setFilter(.all, for: "nba")
        var expected = everyLeague
        expected["nba"] = nil
        XCTAssertEqual(Settings(defaults: defaults).leagueFilters, expected)
    }

    func testInterimFavoritesOnlySetMigrates() {
        let suite = "MacSportsBarTests.favOnlyMigrateSet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["eng.1", "usa.1"], forKey: "favoritesOnlyLeagues")
        XCTAssertEqual(Settings(defaults: defaults).leagueFilters,
                       ["eng.1": .favorites, "usa.1": .favorites])
    }

    func testLegacySwitchOffMigratesToNothingFiltered() {
        let suite = "MacSportsBarTests.favOnlyMigrateOff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "favoritesOnly")
        XCTAssertEqual(Settings(defaults: defaults).leagueFilters, [:])
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
