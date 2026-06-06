import Foundation

/// A selectable team in a league, for the favorites picker.
struct TeamInfo: Identifiable, Equatable {
    /// Team abbreviation — the stable key stored in favorites.
    let id: String
    /// Full display name, e.g. "Atlanta Hawks".
    let name: String
    /// Logo image URL (ESPN CDN), if available.
    let logoURL: URL?
}

/// Fetches and caches the team list (name + logo) for a league from ESPN's `/teams` endpoint —
/// the data behind the favorites picker. Only meaningful for team sports; individual sports
/// (golf, racing) have no team list and return an empty array.
@MainActor
final class TeamDirectory: ObservableObject {
    private let client: ESPNClient
    private var cache: [String: [TeamInfo]] = [:]

    init(client: ESPNClient = ESPNClient()) {
        self.client = client
    }

    /// Teams for a league, cached after the first fetch. Returns `[]` on any failure so the UI
    /// degrades to no logos rather than erroring.
    func teams(for league: LeagueID) async -> [TeamInfo] {
        if let cached = cache[league.league] { return cached }
        let result: [TeamInfo]
        do {
            let payload = try await client.resource(
                sport: league.sport, league: league.league, "teams", as: TeamsPayload.self)
            result = Self.parse(payload)
        } catch {
            result = []
        }
        cache[league.league] = result
        return result
    }

    /// Pure decode → model mapping — the seam the tests exercise.
    nonisolated static func parse(_ payload: TeamsPayload) -> [TeamInfo] {
        let entries = payload.sports?.first?.leagues?.first?.teams ?? []
        return entries.compactMap { entry in
            guard let team = entry.team, let abbreviation = team.abbreviation else { return nil }
            return TeamInfo(
                id: abbreviation,
                name: team.displayName ?? abbreviation,
                logoURL: team.logos?.first?.href.flatMap { URL(string: $0) }
            )
        }
    }
}

// MARK: - Raw JSON (defensive: everything optional)

struct TeamsPayload: Decodable {
    let sports: [Sport]?

    struct Sport: Decodable { let leagues: [League]? }
    struct League: Decodable { let teams: [Entry]? }
    struct Entry: Decodable { let team: Team? }

    struct Team: Decodable {
        let id: String?
        let abbreviation: String?
        let displayName: String?
        let logos: [Logo]?
    }

    struct Logo: Decodable { let href: String? }
}
