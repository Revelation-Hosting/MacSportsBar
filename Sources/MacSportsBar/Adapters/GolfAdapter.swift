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
        // ESPN can lag the *event* state behind the *competition* state — after a playoff the
        // event still says "in" while the competition is marked completed ("Playoff - Play
        // Complete"). Trust completion so a finished tournament shows the winner, not "Playoff".
        let compType = competition.status?.type
        let state = (compType?.completed == true || compType?.state == "post")
            ? "post"
            : (event.status?.type?.state ?? compType?.state ?? "pre")
        let isFav = isFavorite(leader.athlete)
        let id = event.id ?? short

        switch state {
        case "in":
            var line = "\(short) · \(leaderLine)"
            let round = competition.status?.period
            if let round, round > 4 {
                line += " · Playoff"                             // stroke play is 4 rounds; 5+ = sudden death
            } else if let thru = leader.status?.thru ?? holesThrough(leader, round: round), thru > 0 {
                line += thru >= 18 ? " · F" : " thru \(thru)"   // holes done this round, or finished
            } else if let round, round > 0 {
                line += " · R\(round)"                            // round not yet started
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

    /// Holes completed in the player's current round, counted from the per-hole linescores ESPN
    /// appends live (its documented `status.thru` is null in the PGA scoreboard, so this is how
    /// "thru N" is actually known). Returns 18 when the round is complete; nil when the current
    /// round hasn't started, so the caller falls back to the round number. Pure — a tested seam.
    func holesThrough(_ competitor: Scoreboard.Competitor, round: Int?) -> Int? {
        let rounds = competitor.linescores ?? []
        let current = round.flatMap { r in rounds.first { $0.period == r } } ?? rounds.last
        let holes = current?.linescores?.count ?? 0
        return holes > 0 ? holes : nil
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
            /// Per-round scores; each round nests per-hole entries that ESPN appends live as the
            /// player completes holes — the real source of "holes through" (see `holesThrough`),
            /// since `status.thru` is documented but never populated in the PGA scoreboard.
            let linescores: [Linescore]?
        }

        struct Linescore: Decodable {
            let period: Int?            // round number (1–4)
            let linescores: [HoleScore]?  // per-hole entries; count = holes completed this round
        }

        /// A single hole's entry — only its presence matters (we count them), so no fields.
        struct HoleScore: Decodable {}

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
