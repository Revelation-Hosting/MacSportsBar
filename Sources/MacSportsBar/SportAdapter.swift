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

extension LeagueID {
    /// SF Symbol used as the league glyph in the menu bar and dropdown. Monochrome template
    /// symbols render crisply at menu-bar size and adapt to light/dark (unlike color logos).
    var symbolName: String {
        switch sport {
        case "basketball": return "basketball.fill"
        case "baseball":   return "baseball.fill"
        case "football":   return "football.fill"
        case "hockey":     return "hockey.puck.fill"
        case "soccer":     return "soccerball"
        case "golf":       return "figure.golf"
        case "racing":     return "flag.checkered"
        default:           return "sportscourt.fill"
        }
    }
}

/// One adapter per data *shape*. Each adapter owns its own fetch + decode + format so a
/// breaking upstream change stays a localized, one-file fix.
protocol SportAdapter {
    var league: LeagueID { get }
    /// Fetch and normalize events for this league. `dates` (YYYYMMDD) selects a specific day
    /// (for the ±24h favorites window); nil fetches the default day (today).
    func fetch(using client: ESPNClient, dates: String?) async throws -> [SportEvent]
}

extension SportAdapter {
    /// Convenience: today's events.
    func fetch(using client: ESPNClient) async throws -> [SportEvent] {
        try await fetch(using: client, dates: nil)
    }
}
