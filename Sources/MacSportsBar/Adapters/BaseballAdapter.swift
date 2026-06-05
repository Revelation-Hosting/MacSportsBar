import Foundation

/// Decodes ESPN's MLB scoreboard JSON into compact menu-bar strings, including live
/// base/out state. Self-contained (its own `Codable` models) so an upstream change to
/// baseball can't break the other sports — per the spec's adapter-isolation principle.
struct BaseballAdapter: SportAdapter {
    let league: LeagueID
    /// Lowercased team abbreviations/names the user follows. Empty = no favorites.
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
        let id = event.id ?? "\(awayAbbr)-\(homeAbbr)"

        switch state {
        case "in":
            let detail = liveDetail(status: status, situation: competition.situation)
            return SportEvent(id: id, state: .live, displayString: join(scoreLine, detail),
                              isFavorite: isFav, sortPriority: isFav ? 1000 : 800)
        case "post":
            return SportEvent(id: id, state: .final, displayString: join(scoreLine, "Final"),
                              isFavorite: isFav, sortPriority: isFav ? 300 : 100)
        default: // "pre"
            let start = parseDate(event.date)
            let timeLabel = start.map { Self.timeFormatter.string(from: $0) }
                ?? (status?.type?.shortDetail ?? "")
            return SportEvent(id: id, state: .pre(startDate: start),
                              displayString: join("\(awayAbbr) vs \(homeAbbr)", timeLabel),
                              isFavorite: isFav, sortPriority: isFav ? 600 : 400)
        }
    }

    /// Live detail, e.g. `Bot 7th · 2 out · [1_3]` for an active half-inning; just the inning
    /// label (`End 1st`, `Mid 3rd`) between halves, where outs and bases are meaningless.
    func liveDetail(status: Scoreboard.Status?, situation: Scoreboard.Situation?) -> String {
        let inning = inningLabel(status)
        let lowered = inning.lowercased()
        let isActiveHalf = lowered.hasPrefix("top") || lowered.hasPrefix("bot")
        guard isActiveHalf, let situation else { return inning }
        var parts = [inning]
        if let outs = situation.outs { parts.append("\(outs) out") }
        parts.append(basesGlyph(situation))
        return parts.joined(separator: " · ")
    }

    /// ESPN preformats `Top 5th` / `Bottom 7th` / `Mid 3rd` / `End 1st`; we prefer it and
    /// shorten `Bottom` → `Bot` to fit the menu bar.
    func inningLabel(_ status: Scoreboard.Status?) -> String {
        if let detail = status?.type?.shortDetail, !detail.isEmpty {
            return detail.replacingOccurrences(of: "Bottom", with: "Bot")
        }
        if let period = status?.period { return "Inning \(period)" }
        return "In Progress"
    }

    /// Three-slot base state: `[1_3]` (first & third), `[___]` (empty), `[123]` (loaded).
    func basesGlyph(_ s: Scoreboard.Situation) -> String {
        let first = (s.onFirst ?? false) ? "1" : "_"
        let second = (s.onSecond ?? false) ? "2" : "_"
        let third = (s.onThird ?? false) ? "3" : "_"
        return "[\(first)\(second)\(third)]"
    }

    // MARK: - Helpers (kept local to preserve adapter isolation)

    private func abbr(of competitor: Scoreboard.Competitor) -> String {
        competitor.team?.abbreviation ?? competitor.team?.shortDisplayName ?? "—"
    }

    private func isFavorite(_ competitor: Scoreboard.Competitor) -> Bool {
        guard !favorites.isEmpty else { return false }
        let names = [
            competitor.team?.abbreviation,
            competitor.team?.displayName,
            competitor.team?.shortDisplayName,
            competitor.team?.location
        ].compactMap { $0?.lowercased() }
        return names.contains { name in favorites.contains { name == $0 || name.contains($0) } }
    }

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

    private static let isoFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f
        }
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f
    }()
}

// MARK: - Raw JSON (defensive: everything optional)

extension BaseballAdapter {
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
            let situation: Situation?
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
        }

        struct Status: Decodable {
            let period: Int?
            let type: StatusType?
        }

        struct StatusType: Decodable {
            let state: String?
            let completed: Bool?
            let shortDetail: String?
        }

        struct Situation: Decodable {
            let balls: Int?
            let strikes: Int?
            let outs: Int?
            let onFirst: Bool?
            let onSecond: Bool?
            let onThird: Bool?
        }
    }
}
