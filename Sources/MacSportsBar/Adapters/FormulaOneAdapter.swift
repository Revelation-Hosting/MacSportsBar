import Foundation

/// Decodes ESPN's Formula 1 scoreboard into one `SportEvent` per **notable session** — qualifying,
/// sprint, and the race — so a weekend reads as "when's qualifying" and "when's the race" rather
/// than one opaque blob. Practice is deliberately skipped (see `isPractice`).
///
/// F1 is the one league where ESPN models sessions natively: a single event carries five sibling
/// `competitions` (FP1/FP2/FP3/Qual/Race), each with its own status, date, and classification.
/// Two traps come with that, both guarded here and covered by tests:
///
/// 1. **The event-level status lies.** On a live weekend ESPN reports the *event* as
///    `STATUS_FINAL / post / completed:true` while the race competition is still `STATUS_SCHEDULED`
///    for two days out. Only the per-competition status is trustworthy.
/// 2. **`STATUS_CANCELED` is `state: "post"`** with `completed: false`, so the usual
///    `state == "post" → final` rule would render a cancelled Grand Prix as a finished race.
///
/// ⚠️ **No live telemetry, by design.** ESPN reports `liveAvailable: false` and
/// `gameSource: "scrubbed"` for F1 — classifications appear after a session, not during it — and
/// OpenF1's live tier (flags, safety car, VSC, the qualifying clock) is a paid subscription. So
/// this shows the schedule and each session's result, and never claims a live readout.
/// Constructors come from `OpenF1Client` (ESPN has no team data for F1 at all).
struct FormulaOneAdapter: SportAdapter {
    let league: LeagueID
    /// Lowercased favorite driver names. Empty = no favorites.
    let favorites: Set<String>
    /// Driver-surname → constructor lookup. Injected so tests stay hermetic; production reads the
    /// process-wide cached directory.
    var constructors: @Sendable () async -> [String: F1Constructor] = {
        await OpenF1ConstructorDirectory.shared.constructors()
    }

    func fetch(using client: ESPNClient, dates: String?) async throws -> [SportEvent] {
        let payload = try await client.scoreboard(
            sport: league.sport, league: league.league, dates: dates, as: Scoreboard.self
        )
        let teams = await constructors()
        return (payload.events ?? []).flatMap { map($0, constructors: teams) }
    }

    // MARK: - Mapping

    /// Maps one Grand Prix weekend into a `SportEvent` per notable session. Returns `[]` for a
    /// cancelled Grand Prix. Pure — the seam the tests exercise.
    func map(_ event: Scoreboard.Event, constructors: [String: F1Constructor]) -> [SportEvent] {
        // A cancelled GP reports state "post" but completed:false — emit nothing rather than a
        // phantom "final".
        if Self.isCanceled(event.status) { return [] }
        let grandPrix = Self.grandPrixName(event)

        return (event.competitions ?? []).compactMap { competition in
            guard let abbreviation = competition.type?.abbreviation,
                  !Self.isPractice(abbreviation) else { return nil }
            if Self.isCanceled(competition.status) { return nil }

            let label = Self.sessionLabel(abbreviation)
            let isRace = abbreviation.caseInsensitiveCompare("Race") == .orderedSame
            let start = Self.parseDate(competition.date)
            // NEVER read the event-level status here — on a live weekend it claims the whole GP is
            // final while these sessions are still scheduled.
            let state = competition.status?.type?.state ?? "pre"
            let id = "\(event.id ?? grandPrix)-\(abbreviation)"

            let leader = Self.leader(of: competition)
            let name = leader.map { Self.lastName($0.athlete?.displayName ?? "") } ?? ""
            let team = constructors[name.lowercased()]
            let isFav = isFavorite(leader?.athlete)

            switch state {
            case "in":
                // ESPN is "scrubbed" for F1, so a live session has no usable detail — say so
                // plainly rather than implying live timing we don't have.
                return SportEvent(
                    id: id, league: league, state: .live,
                    displayString: "\(grandPrix) · \(label) · In Progress",
                    isFavorite: isFav, sortPriority: isFav ? 1000 : 800,
                    date: start,
                    menuShort: "\(label) · In Progress")

            case "post":
                let who = Self.credit(driver: name, team: team, won: isRace)
                let detail = isRace ? who : "\(label) · \(who)"
                return SportEvent(
                    id: id, league: league, state: .final,
                    displayString: "\(grandPrix) · \(detail)",
                    isFavorite: isFav, sortPriority: isFav ? 300 : 100,
                    date: start,
                    menuShort: detail,
                    accentHex: team?.colorHex)

            default: // "pre"
                let when = start.map { Self.timeFormatter.string(from: $0) }
                    ?? (competition.status?.type?.shortDetail ?? "")
                let detail = when.isEmpty ? label : "\(label) · \(when)"
                return SportEvent(
                    id: id, league: league, state: .pre(startDate: start),
                    displayString: "\(grandPrix) · \(detail)",
                    isFavorite: isFav, sortPriority: isFav ? 600 : 400,
                    date: start,
                    menuShort: detail)
            }
        }
    }

    // MARK: - Helpers

    /// ESPN marks a cancelled Grand Prix `state: "post"` with `completed: false`, which would
    /// otherwise read as a finished race. Pure — a tested seam.
    nonisolated static func isCanceled(_ status: Scoreboard.Status?) -> Bool {
        guard let type = status?.type else { return false }
        if let name = type.name, name.uppercased().contains("CANCEL") { return true }
        return type.state == "post" && type.completed == false
    }

    /// Practice sessions (FP1/FP2/FP3) are skipped: they'd triple the weekend's rotation slots and
    /// notifications for results nobody glances at a menu bar for.
    nonisolated static func isPractice(_ abbreviation: String) -> Bool {
        abbreviation.uppercased().hasPrefix("FP")
    }

    /// ESPN's terse session abbreviations → what the menu bar prints. Unknown values (a sprint
    /// weekend's extra sessions) pass through unchanged rather than being dropped.
    nonisolated static func sessionLabel(_ abbreviation: String) -> String {
        switch abbreviation.lowercased() {
        case "qual": return "Qualifying"
        case "race": return "Race"
        case "sprint": return "Sprint"
        case "sq", "sprintqual", "sprint qual": return "Sprint Quali"
        default: return abbreviation
        }
    }

    /// `Hungary GP` — from the circuit's country, which is sponsor-free. ESPN's `name` and
    /// `shortName` are prefixed with a rotating sponsor ("AWS Hungarian GP", "Moët & Chandon
    /// Belgian GP"), so they're only a fallback. Pure — a tested seam.
    nonisolated static func grandPrixName(_ event: Scoreboard.Event) -> String {
        if let country = event.circuit?.address?.country, !country.isEmpty { return "\(country) GP" }
        if let short = event.shortName, !short.isEmpty { return short }
        return event.name ?? "Grand Prix"
    }

    /// "Norris won (McLaren)" for a race, "Norris (McLaren)" for qualifying — dropping the team
    /// when OpenF1 didn't supply one. Pure — a tested seam.
    nonisolated static func credit(driver: String, team: F1Constructor?, won: Bool) -> String {
        guard !driver.isEmpty else { return won ? "Final" : "Complete" }
        let verb = won ? "\(driver) won" : driver
        guard let team else { return verb }
        return "\(verb) (\(team.name))"
    }

    /// P1 of a session: the winner if flagged, else the first finishing position.
    private static func leader(of competition: Scoreboard.Competition) -> Scoreboard.Competitor? {
        let competitors = competition.competitors ?? []
        return competitors.first { $0.winner == true }
            ?? competitors.first { $0.order == 1 }
            ?? competitors.first
    }

    /// Driver surname, skipping a generational suffix. Pure — a tested seam.
    nonisolated static func lastName(_ full: String) -> String {
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

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    // ESPN dates look like `2026-07-26T13:00Z` (no seconds), which the strict ISO8601 parser
    // rejects — handle both shapes, in UTC.
    private static let isoFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f
        }
    }()

    // Local-time session label, e.g. `Sat 7:00a`.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f
    }()
}

// MARK: - Raw JSON (defensive: everything optional)

extension FormulaOneAdapter {
    struct Scoreboard: Decodable {
        let events: [Event]?

        struct Event: Decodable {
            let id: String?
            let name: String?
            let shortName: String?
            let date: String?
            let status: Status?
            let circuit: Circuit?
            /// One entry per session (FP1/FP2/FP3/Qual/Race) — not the usual single competition.
            let competitions: [Competition]?
        }

        struct Circuit: Decodable {
            let fullName: String?
            let address: Address?
        }

        struct Address: Decodable {
            let city: String?
            let country: String?
        }

        struct Competition: Decodable {
            let date: String?
            let type: SessionType?
            let status: Status?
            let competitors: [Competitor]?
        }

        struct SessionType: Decodable {
            let abbreviation: String?
        }

        struct Competitor: Decodable {
            let order: Int?
            let winner: Bool?
            let athlete: Athlete?
        }

        struct Athlete: Decodable {
            let displayName: String?
            let shortName: String?
        }

        struct Status: Decodable {
            /// Lap count on a completed race; 0 before a session runs.
            let period: Int?
            let type: StatusType?
        }

        struct StatusType: Decodable {
            let name: String?
            let state: String?
            let completed: Bool?
            let description: String?
            let shortDetail: String?
        }
    }
}
