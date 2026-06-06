import Foundation

/// Decodes ESPN basketball scoreboard JSON for both NBA and NCAA Men's. The two leagues
/// share a shape; only the period label differs (NBA quarters vs NCAA halves), keyed off
/// `league.league`.
///
/// Decoding is intentionally defensive — every field is optional and the mapper degrades
/// to a usable string rather than dropping events or crashing.
struct BasketballAdapter: SportAdapter {
    let league: LeagueID
    /// Lowercased team abbreviations/names the user follows. Empty = no favorites (M1).
    let favorites: Set<String>

    func fetch(using client: ESPNClient) async throws -> [SportEvent] {
        let payload = try await client.scoreboard(
            sport: league.sport, league: league.league, as: Scoreboard.self
        )
        return (payload.events ?? []).compactMap(map)
    }

    // MARK: - Mapping

    /// Maps one decoded ESPN event into a normalized `SportEvent`, or `nil` if it lacks the
    /// minimum two competitors. Pure (no I/O) — the seam the formatting tests exercise.
    func map(_ event: Scoreboard.Event) -> SportEvent? {
        guard let competition = event.competitions?.first else { return nil }
        let competitors = competition.competitors ?? []
        guard competitors.count >= 2 else { return nil }

        let home = competitors.first { $0.homeAway == "home" } ?? competitors[0]
        let away = competitors.first { $0.homeAway == "away" } ?? competitors[1]

        let homeAbbr = abbr(of: home)
        let awayAbbr = abbr(of: away)
        let status = event.status ?? competition.status
        let state = status?.type?.state ?? "pre"

        let isFav = isFavorite(home) || isFavorite(away)
        let scoreLine = "\(awayAbbr) \(away.score ?? "0")  \(homeAbbr) \(home.score ?? "0")"

        switch state {
        case "in":
            let clock = status?.displayClock ?? ""
            let period = periodLabel(status?.period)
            let detail = [clock, period].filter { !$0.isEmpty }.joined(separator: " ")
            return SportEvent(
                id: event.id ?? "\(awayAbbr)-\(homeAbbr)",
                league: league,
                state: .live,
                displayString: join(scoreLine, detail),
                isFavorite: isFav,
                sortPriority: isFav ? 1000 : 800,
                period: status?.period,
                awayLogo: logoURL(away),
                homeLogo: logoURL(home),
                matchup: .init(away: awayAbbr, awayScore: away.score ?? "0",
                               home: homeAbbr, homeScore: home.score ?? "0", detail: detail)
            )

        case "post":
            return SportEvent(
                id: event.id ?? "\(awayAbbr)-\(homeAbbr)",
                league: league,
                state: .final,
                displayString: join(scoreLine, "Final"),
                isFavorite: isFav,
                sortPriority: isFav ? 300 : 100
            )

        default: // "pre"
            let start = parseDate(event.date)
            let timeLabel = start.map { Self.timeFormatter.string(from: $0) }
                ?? (status?.type?.shortDetail ?? "")
            return SportEvent(
                id: event.id ?? "\(awayAbbr)-\(homeAbbr)",
                league: league,
                state: .pre(startDate: start),
                displayString: join("\(awayAbbr) vs \(homeAbbr)", timeLabel),
                isFavorite: isFav,
                sortPriority: isFav ? 600 : 400
            )
        }
    }

    private func abbr(of competitor: Scoreboard.Competitor) -> String {
        competitor.team?.abbreviation ?? competitor.team?.shortDisplayName ?? "—"
    }

    private func logoURL(_ competitor: Scoreboard.Competitor) -> URL? {
        competitor.team?.logo.flatMap { URL(string: $0) }
    }

    /// NBA: Q1–Q4 then OT/2OT. NCAA Men's: 1H/2H then OT/2OT.
    func periodLabel(_ period: Int?) -> String {
        guard let period, period > 0 else { return "" }
        if league.league == "nba" {
            if period <= 4 { return "Q\(period)" }
            return period == 5 ? "OT" : "\(period - 4)OT"
        } else {
            if period <= 2 { return "\(period)H" }
            return period == 3 ? "OT" : "\(period - 2)OT"
        }
    }

    private func isFavorite(_ competitor: Scoreboard.Competitor) -> Bool {
        guard !favorites.isEmpty else { return false }
        let candidates = [
            competitor.team?.abbreviation,
            competitor.team?.displayName,
            competitor.team?.shortDisplayName,
            competitor.team?.location
        ].compactMap { $0?.lowercased() }
        return candidates.contains { name in favorites.contains { name == $0 || name.contains($0) } }
    }

    /// Joins a score line and a detail with the menu-bar separator, omitting empties.
    private func join(_ lhs: String, _ rhs: String) -> String {
        rhs.isEmpty ? lhs : "\(lhs) · \(rhs)"
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        for formatter in Self.isoFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    // ESPN scoreboard dates look like `2026-06-06T00:30Z` (no seconds), so the strict
    // ISO8601 parser rejects them — handle both with/without seconds, in UTC.
    private static let isoFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f
        }
    }()

    // Local-time start label, e.g. `8:30p`.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f
    }()
}

// MARK: - Raw JSON (defensive: everything optional)

extension BasketballAdapter {
    struct Scoreboard: Decodable {
        let events: [Event]?

        struct Event: Decodable {
            let id: String?
            let date: String?
            let status: Status?
            let competitions: [Competition]?
        }

        struct Competition: Decodable {
            let competitors: [Competitor]?
            let status: Status?
        }

        struct Competitor: Decodable {
            let homeAway: String?
            let score: String?
            let team: Team?
        }

        struct Team: Decodable {
            let abbreviation: String?
            let displayName: String?
            let shortDisplayName: String?
            let location: String?
            let logo: String?
        }

        struct Status: Decodable {
            let displayClock: String?
            let period: Int?
            let type: StatusType?
        }

        struct StatusType: Decodable {
            let state: String?
            let completed: Bool?
            let description: String?
            let shortDetail: String?
        }
    }
}
