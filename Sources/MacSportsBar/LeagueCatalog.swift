import Foundation

/// A sport/league the app can fetch, paired with a factory for its adapter.
struct SupportedLeague: Identifiable {
    /// League slug, e.g. `"nba"` — also the persistence key for the enable toggle.
    let id: String
    let league: LeagueID
    /// Builds the adapter for this league given the user's favorite tokens.
    let makeAdapter: (Set<String>) -> SportAdapter
}

/// Registry of implemented leagues. Add an entry here as each adapter lands; the settings
/// toggles and the polling loop pick it up automatically.
enum LeagueCatalog {
    static let all: [SupportedLeague] = {
        let nba = LeagueID(sport: "basketball", league: "nba", displayName: "NBA")
        let mlb = LeagueID(sport: "baseball", league: "mlb", displayName: "MLB")
        let pga = LeagueID(sport: "golf", league: "pga", displayName: "PGA")
        let nascar = LeagueID(sport: "racing", league: "nascar-premier", displayName: "NASCAR")
        return [
            SupportedLeague(
                id: nba.league,
                league: nba,
                makeAdapter: { BasketballAdapter(league: nba, favorites: $0) }
            ),
            SupportedLeague(
                id: mlb.league,
                league: mlb,
                makeAdapter: { BaseballAdapter(league: mlb, favorites: $0) }
            ),
            SupportedLeague(
                id: pga.league,
                league: pga,
                makeAdapter: { GolfAdapter(league: pga, favorites: $0) }
            ),
            SupportedLeague(
                id: nascar.league,
                league: nascar,
                makeAdapter: { RacingAdapter(league: nascar, favorites: $0) }
            )
        ]
    }()
}
