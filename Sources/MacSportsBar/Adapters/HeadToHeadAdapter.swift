import Foundation

/// Generic adapter for the head-to-head ESPN scoreboard shape shared by football, hockey,
/// and soccer (two competitors, a score, and a period clock). The per-sport differences —
/// how the live "detail" reads — are captured by `PeriodStyle`.
///
/// Basketball and baseball keep their own adapters: baseball needs base/out state, and both
/// predate this and are independently unit-tested. This handles the newer leagues.
struct HeadToHeadAdapter: SportAdapter {
    /// How the live detail segment is rendered.
    enum PeriodStyle {
        case quarters   // Q1–Q4 then OT/2OT (NFL, NCAA football)
        case hockey     // 1st/2nd/3rd then OT/SO (NHL)
        case soccer     // match minute, e.g. 67' / HT (preformatted by ESPN)
    }

    let league: LeagueID
    /// Lowercased favorite team names/abbreviations. Empty = no favorites.
    let favorites: Set<String>
    let style: PeriodStyle

    func fetch(using client: ESPNClient) async throws -> [SportEvent] {
        let payload = try await client.scoreboard(
            sport: league.sport, league: league.league, as: Scoreboard.self
        )
        return (payload.events ?? []).compactMap(map)
    }

    // MARK: - Mapping

    /// Maps one decoded event into a `SportEvent`, or `nil` without two competitors. Pure —
    /// the seam the formatting tests exercise.
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
            let detail = liveDetail(status)
            return SportEvent(id: id, league: league, state: .live,
                              displayString: join(scoreLine, detail),
                              isFavorite: isFav, sortPriority: isFav ? 1000 : 800, period: status?.period,
                              awayLogo: logoURL(away), homeLogo: logoURL(home),
                              matchup: .init(away: awayAbbr, awayScore: away.score ?? "0",
                                             home: homeAbbr, homeScore: home.score ?? "0", detail: detail))
        case "post":
            return SportEvent(id: id, league: league, state: .final,
                              displayString: join(scoreLine, "Final"),
                              isFavorite: isFav, sortPriority: isFav ? 300 : 100)
        default: // "pre"
            let start = parseDate(event.date)
            return SportEvent(id: id, league: league, state: .pre(startDate: start),
                              displayString: join("\(awayAbbr) vs \(homeAbbr)", preLabel(start, fallback: status)),
                              isFavorite: isFav, sortPriority: isFav ? 600 : 400)
        }
    }

    /// Live detail, e.g. `7:30 Q4` (football), `4:11 2nd` (hockey), `67'` (soccer).
    func liveDetail(_ status: Scoreboard.Status?) -> String {
        switch style {
        case .soccer:
            // ESPN preformats the minute / half (e.g. "67'", "HT") in shortDetail.
            if let detail = status?.type?.shortDetail, !detail.isEmpty { return detail }
            return status?.displayClock ?? ""
        case .quarters, .hockey:
            let clock = status?.displayClock ?? ""
            let period = periodLabel(status?.period, detail: status?.type?.shortDetail)
            return [clock, period].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// Period label for clock-based sports. Soccer returns "" (it uses the minute instead).
    ///
    /// `detail` is ESPN's `shortDetail`, used only to disambiguate NHL period 5: a
    /// regular-season game decided there is a shootout ("SO"), but the playoffs have no
    /// shootout — period 4 is the 1st OT, period 5 the 2nd ("2OT"), period 6 the 3rd, etc.
    func periodLabel(_ period: Int?, detail: String? = nil) -> String {
        guard let period, period > 0 else { return "" }
        switch style {
        case .quarters:
            if period <= 4 { return "Q\(period)" }
            return period == 5 ? "OT" : "\(period - 4)OT"
        case .hockey:
            switch period {
            case 1: return "1st"
            case 2: return "2nd"
            case 3: return "3rd"
            case 4: return "OT"
            default:
                // Period 5+ is multi-OT in the playoffs, but a regular-season game ending in
                // period 5 is a shootout. Trust the feed when it names one; otherwise count OTs.
                if period == 5, isShootout(detail) { return "SO" }
                return "\(period - 3)OT"
            }
        case .soccer:
            return ""
        }
    }

    /// Whether ESPN's status detail names a shootout. The period number alone can't tell a
    /// regular-season shootout from a playoff 2nd OT (both report period 5), but the detail can.
    private func isShootout(_ detail: String?) -> Bool {
        guard let detail else { return false }
        if detail.lowercased().contains("shootout") { return true }
        // Match the abbreviation "SO" as a standalone token (e.g. "Final/SO"), not as a
        // substring of an unrelated word.
        return detail.range(of: #"\bSO\b"#, options: .regularExpression) != nil
    }

    // MARK: - Helpers

    /// Start label for upcoming games: just the time if it's today, else a day + date so an
    /// off-season game months away (NFL/NCAAF in summer) isn't shown as a bare time.
    private func preLabel(_ date: Date?, fallback status: Scoreboard.Status?) -> String {
        guard let date else { return status?.type?.shortDetail ?? "" }
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private func abbr(of competitor: Scoreboard.Competitor) -> String {
        competitor.team?.abbreviation ?? competitor.team?.shortDisplayName ?? "—"
    }

    private func logoURL(_ competitor: Scoreboard.Competitor) -> URL? {
        competitor.team?.logo.flatMap { URL(string: $0) }
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE M/d"
        return f
    }()
}

// MARK: - Raw JSON (defensive: everything optional)

extension HeadToHeadAdapter {
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
            let shortDetail: String?
        }
    }
}
