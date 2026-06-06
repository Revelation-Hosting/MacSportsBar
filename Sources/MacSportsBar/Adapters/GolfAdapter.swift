import Foundation

/// Decodes ESPN's PGA scoreboard JSON (a *leaderboard* shape, not head-to-head) into one
/// compact string per tournament: short name + current leader + score-to-par, plus the
/// leader's hole (`thru`) during active play or the round number between rounds.
///
/// Golf is intermittent — most days this is a single tournament or nothing. Self-contained
/// (own `Codable`) per the spec's adapter-isolation principle.
struct GolfAdapter: SportAdapter {
    let league: LeagueID
    /// Lowercased favorite player names/abbreviations. Empty = no favorites.
    let favorites: Set<String>

    func fetch(using client: ESPNClient, dates: String?) async throws -> [SportEvent] {
        let payload = try await client.scoreboard(
            sport: league.sport, league: league.league, dates: dates, as: Scoreboard.self
        )
        return (payload.events ?? []).compactMap(map)
    }

    // MARK: - Mapping

    /// Maps one tournament into a `SportEvent`, or `nil` if it has no competitors. Pure — the
    /// seam the formatting tests exercise.
    func map(_ event: Scoreboard.Event) -> SportEvent? {
        guard let competition = event.competitions?.first else { return nil }
        let competitors = competition.competitors ?? []
        guard let leader = competitors.first(where: { $0.order == 1 }) ?? competitors.first
        else { return nil }

        let short = shortTournament(event.name ?? event.shortName ?? "Golf")
        let leaderName = lastName(leader.athlete?.displayName ?? "—")
        let scored = leader.score.map(formatScore) ?? ""
        let leaderLine = scored.isEmpty ? leaderName : "\(leaderName) \(scored)"
        let state = event.status?.type?.state ?? "pre"
        let isFav = isFavorite(leader.athlete)
        let id = event.id ?? short

        switch state {
        case "in":
            var line = "\(short) · \(leaderLine)"
            if let thru = leader.status?.thru, thru > 0, thru < 18 {
                line += " thru \(thru)"            // active round
            } else if let round = competition.status?.period, round > 0 {
                line += " · R\(round)"             // between rounds / round complete
            }
            return SportEvent(id: id, league: league, state: .live,
                              displayString: line, isFavorite: isFav,
                              sortPriority: isFav ? 1000 : 800)

        case "post":
            return SportEvent(id: id, league: league, state: .final,
                              displayString: "\(short) · \(leaderLine) · Final",
                              isFavorite: isFav, sortPriority: isFav ? 300 : 100)

        default: // "pre"
            let start = parseDate(event.date)
            let when = start.map { Self.dateFormatter.string(from: $0) } ?? ""
            return SportEvent(id: id, league: league, state: .pre(startDate: start),
                              displayString: when.isEmpty ? short : "\(short) · \(when)",
                              isFavorite: isFav, sortPriority: isFav ? 600 : 400)
        }
    }

    // MARK: - Helpers

    /// Trim the sponsor suffix and a leading "the" so long official names fit the menu bar,
    /// e.g. "the Memorial Tournament pres. by Workday" → "Memorial Tournament".
    func shortTournament(_ name: String) -> String {
        var s = name
        for marker in [" pres. by", " presented by", " pres by", " pres.by"] {
            if let range = s.range(of: marker, options: .caseInsensitive) {
                s = String(s[..<range.lowerBound])
                break
            }
        }
        if s.lowercased().hasPrefix("the ") { s = String(s.dropFirst(4)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Last token of a player's name, e.g. "J.T. Poston" → "Poston".
    func lastName(_ full: String) -> String {
        full.split(separator: " ").last.map(String.init) ?? full
    }

    /// Render the hyphen-minus ESPN returns as a true minus sign: "-9" → "−9"; "E"/"+2" as-is.
    func formatScore(_ score: String) -> String {
        score.hasPrefix("-") ? "−" + score.dropFirst() : score
    }

    private func isFavorite(_ athlete: Scoreboard.Athlete?) -> Bool {
        guard !favorites.isEmpty, let athlete else { return false }
        let names = [athlete.displayName, athlete.shortName].compactMap { $0?.lowercased() }
        return names.contains { name in favorites.contains { name == $0 || name.contains($0) } }
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        for formatter in Self.isoFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static let isoFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f
        }
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE M/d"
        return f
    }()
}

// MARK: - Raw JSON (defensive: everything optional)

extension GolfAdapter {
    struct Scoreboard: Decodable {
        let events: [Event]?

        struct Event: Decodable {
            let id: String?
            let name: String?
            let shortName: String?
            let date: String?
            let status: Status?
            let competitions: [Competition]?
        }

        struct Competition: Decodable {
            let status: Status?
            let competitors: [Competitor]?
        }

        struct Competitor: Decodable {
            let order: Int?
            let score: String?
            let athlete: Athlete?
            let status: CompetitorStatus?
        }

        struct Athlete: Decodable {
            let displayName: String?
            let shortName: String?
        }

        struct CompetitorStatus: Decodable {
            let thru: Int?
            let hole: Int?
        }

        struct Status: Decodable {
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
