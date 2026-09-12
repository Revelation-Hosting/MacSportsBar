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
            // ESPN caps `/teams` at 50 entries unless told otherwise — fine for the pro
            // leagues, but college football has 700+ teams and the picker silently showed
            // the first 50 (Amherst, Bristol, …) and none of the Big Ten. Ask for everything.
            let payload = try await client.resource(
                sport: league.sport, league: league.league, "teams",
                query: [URLQueryItem(name: "limit", value: "1000")], as: TeamsPayload.self)
            result = Self.parse(payload)
        } catch {
            result = []
        }
        cache[league.league] = result
        return result
    }

    /// Pure decode → model mapping, sorted by display name — the seam the tests exercise.
    /// (ESPN's own order is by slug, which puts "Arizona State" before "Arizona"; in a
    /// 700-team college list an alphabetical scan has to actually be alphabetical.)
    nonisolated static func parse(_ payload: TeamsPayload) -> [TeamInfo] {
        let entries = payload.sports?.first?.leagues?.first?.teams ?? []
        return entries
            .compactMap { entry -> TeamInfo? in
                guard let team = entry.team, let abbreviation = team.abbreviation else { return nil }
                return TeamInfo(
                    id: abbreviation,
                    name: team.displayName ?? abbreviation,
                    logoURL: team.logos?.first?.href.flatMap { URL(string: $0) }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What the picker actually lists: the `query` matches, capped at `cap` rows so a 700-team
    /// college list doesn't mount 700 logo-loading rows at once. Teams already `selected`
    /// (lowercased abbreviations) always make the cut, so a pick never disappears behind the
    /// cap. Returns how many matches were left out, for a "search to narrow" hint. Pure.
    nonisolated static func visible(
        _ teams: [TeamInfo], query: String, selected: Set<String>, cap: Int
    ) -> (shown: [TeamInfo], hidden: Int) {
        let matches = filter(teams, query: query)
        guard matches.count > cap else { return (matches, 0) }
        let picked = matches.filter { selected.contains($0.id.lowercased()) }
        let rest = matches.filter { !selected.contains($0.id.lowercased()) }
        let shown = picked + rest.prefix(max(0, cap - picked.count))
        return (shown, matches.count - shown.count)
    }

    /// Teams whose name or abbreviation contains `query` (case-insensitive); everything when
    /// the query is blank. Pure — the picker's search seam.
    nonisolated static func filter(_ teams: [TeamInfo], query: String) -> [TeamInfo] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return teams }
        return teams.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.id.localizedCaseInsensitiveContains(needle)
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
