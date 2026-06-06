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
        let nfl = LeagueID(sport: "football", league: "nfl", displayName: "NFL")
        let nhl = LeagueID(sport: "hockey", league: "nhl", displayName: "NHL")
        let ncaaf = LeagueID(sport: "football", league: "college-football", displayName: "NCAAF")
        let epl = LeagueID(sport: "soccer", league: "eng.1", displayName: "Premier League")
        let ucl = LeagueID(sport: "soccer", league: "uefa.champions", displayName: "Champions League")
        let mls = LeagueID(sport: "soccer", league: "usa.1", displayName: "MLS")
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
            ),
            SupportedLeague(id: nfl.league, league: nfl,
                            makeAdapter: { HeadToHeadAdapter(league: nfl, favorites: $0, style: .quarters) }),
            SupportedLeague(id: nhl.league, league: nhl,
                            makeAdapter: { HeadToHeadAdapter(league: nhl, favorites: $0, style: .hockey) }),
            SupportedLeague(id: ncaaf.league, league: ncaaf,
                            makeAdapter: { HeadToHeadAdapter(league: ncaaf, favorites: $0, style: .quarters) }),
            SupportedLeague(id: epl.league, league: epl,
                            makeAdapter: { HeadToHeadAdapter(league: epl, favorites: $0, style: .soccer) }),
            SupportedLeague(id: ucl.league, league: ucl,
                            makeAdapter: { HeadToHeadAdapter(league: ucl, favorites: $0, style: .soccer) }),
            SupportedLeague(id: mls.league, league: mls,
                            makeAdapter: { HeadToHeadAdapter(league: mls, favorites: $0, style: .soccer) })
        ]
    }()
}
