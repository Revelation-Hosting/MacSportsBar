import Foundation

/// Decodes ESPN's NASCAR Cup scoreboard JSON (a *field* shape) into one compact string per
/// race: short track/race name + the current leader (or winner / scheduled time).
///
/// ⚠️ Degraded by design. Live lap/stage/leader telemetry lives in the per-event detail
/// endpoint (`sports.core.api.espn.com/.../events/{id}/...`), reachable via each event's
/// `$ref` — and the exact field paths can only be confirmed against a green-flag Cup race.
/// Until that's verified, this shows the leader from the scoreboard's running order and
/// omits lap/stage. Upgrading to `… · L245/400 · St3 · #5 Larson` is a future enhancement.
struct RacingAdapter: SportAdapter {
    let league: LeagueID
    /// Lowercased favorite driver names. Empty = no favorites.
    let favorites: Set<String>

    func fetch(using client: ESPNClient) async throws -> [SportEvent] {
        let payload = try await client.scoreboard(
            sport: league.sport, league: league.league, as: Scoreboard.self
        )
        return (payload.events ?? []).map(map)
    }

    // MARK: - Mapping

    /// Maps one race into a `SportEvent`. Pure — the seam the formatting tests exercise. A
    /// scheduled race has no competitors yet, which is fine (the `pre` branch ignores them).
    func map(_ event: Scoreboard.Event) -> SportEvent {
        let short = shortRace(event.name ?? event.shortName ?? "Race")
        let competitors = event.competitions?.first?.competitors ?? []
        let leader = competitors.first(where: { $0.order == 1 }) ?? competitors.first
        let leaderName = leader.map { lastName($0.athlete?.displayName ?? $0.athlete?.shortName ?? "") }
        let state = event.status?.type?.state ?? "pre"
        let isFav = isFavorite(leader?.athlete)
        let id = event.id ?? short

        switch state {
        case "in":
            let detail = leaderName.flatMap { $0.isEmpty ? nil : "\($0) leading" } ?? "In Progress"
            return SportEvent(id: id, league: league, state: .live,
                              displayString: "\(short) · \(detail)",
                              isFavorite: isFav, sortPriority: isFav ? 1000 : 800)

        case "post":
            let detail = leaderName.flatMap { $0.isEmpty ? nil : "\($0) won" } ?? "Final"
            return SportEvent(id: id, league: league, state: .final,
                              displayString: "\(short) · \(detail)",
                              isFavorite: isFav, sortPriority: isFav ? 300 : 100)

        default: // "pre"
            let start = parseDate(event.date)
            let when = start.map { Self.dateFormatter.string(from: $0) }
                ?? (event.status?.type?.shortDetail ?? "")
            return SportEvent(id: id, league: league, state: .pre(startDate: start),
                              displayString: when.isEmpty ? "\(short) · Cup" : "\(short) · Cup · \(when)",
                              isFavorite: isFav, sortPriority: isFav ? 600 : 400)
        }
    }

    // MARK: - Helpers

    /// "NASCAR Cup Series at Michigan" → "Michigan"; sponsor names like "Coca-Cola 600" pass
    /// through unchanged.
    func shortRace(_ name: String) -> String {
        if let range = name.range(of: " at ", options: .backwards) {
            return String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        var s = name
        for prefix in ["NASCAR Cup Series", "NASCAR Cup"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// Driver surname, skipping a trailing generational suffix: "Ricky Stenhouse Jr." → "Stenhouse".
    func lastName(_ full: String) -> String {
        let parts = full.split(separator: " ").map(String.init)
        guard let last = parts.last else { return full }
        let suffixes: Set<String> = ["Jr.", "Sr.", "Jr", "Sr", "II", "III", "IV"]
        if suffixes.contains(last), parts.count >= 2 { return parts[parts.count - 2] }
        return last
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
        f.dateFormat = "EEE h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f
    }()
}

// MARK: - Raw JSON (defensive: everything optional)

extension RacingAdapter {
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
            let athlete: Athlete?
        }

        struct Athlete: Decodable {
            let displayName: String?
            let shortName: String?
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
