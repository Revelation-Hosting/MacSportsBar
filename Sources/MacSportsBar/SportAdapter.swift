import Foundation

/// Identifies an ESPN sport + league pair, e.g. `basketball` / `nba`.
struct LeagueID {
    /// ESPN sport path segment, e.g. `"basketball"`, `"baseball"`.
    let sport: String
    /// ESPN league slug, e.g. `"nba"` or `"mens-college-basketball"`.
    let league: String
    /// Human-readable name for menus and settings.
    let displayName: String
}

/// One adapter per data *shape*. Each adapter owns its own fetch + decode + format so a
/// breaking upstream change stays a localized, one-file fix.
protocol SportAdapter {
    var league: LeagueID { get }
    /// Fetch and normalize the current events for this league.
    func fetch(using client: ESPNClient) async throws -> [SportEvent]
}
