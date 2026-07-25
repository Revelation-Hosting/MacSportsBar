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
/// ESPN alone can't show a session in progress (`liveAvailable: false`, `gameSource: "scrubbed"` —
/// classifications land *after* a session) and carries no team data at all, so live state comes
/// from `F1LiveTimingClient` — Formula 1's own feed, which serves timing topics unauthenticated.
/// That's an enhancement, never a dependency: if the feed is unreachable (its WAF rejects some
/// networks) or the session isn't running, this degrades to ESPN's schedule + results.
/// `OpenF1Client` supplies constructors for those ESPN-only results.
struct FormulaOneAdapter: SportAdapter {
    let league: LeagueID
    /// Lowercased favorite driver names. Empty = no favorites.
    let favorites: Set<String>
    /// Driver-surname → constructor lookup. Injected so tests stay hermetic; production reads the
    /// process-wide cached directory.
    var constructors: @Sendable () async -> [String: F1Constructor] = {
        await OpenF1ConstructorDirectory.shared.constructors()
    }
    /// F1's own live timing feed, consulted only for today. Returns nil when the session isn't
    /// live or the feed is unreachable (some networks are WAF-blocked) — F1 then degrades to
    /// ESPN's schedule + results, exactly as it did before live support existed.
    var liveSnapshot: @Sendable () async -> F1LiveSnapshot? = {
        try? await F1LiveTimingClient().snapshot()
    }

    func fetch(using client: ESPNClient, dates: String?) async throws -> [SportEvent] {
        let payload = try await client.scoreboard(
            sport: league.sport, league: league.league, dates: dates, as: Scoreboard.self
        )
        let teams = await constructors()
        var events = (payload.events ?? []).flatMap { map($0, constructors: teams) }

        // Live only concerns today's sessions, so skip it for adjacent-day window fetches.
        guard dates == nil, let snapshot = await liveSnapshot(), snapshot.isLive() else { return events }
        guard let live = Self.liveReadout(from: snapshot) else { return events }

        // Replace the matching scheduled session with the live one; if ESPN hasn't listed it
        // (its F1 status lags badly), surface the live session on its own.
        if let index = events.firstIndex(where: { Self.matches(event: $0, live: live) }) {
            events[index] = Self.applyLive(live, to: events[index])
        } else {
            events.append(Self.liveEvent(live, league: league))
        }
        return events
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
                    accentHex: team?.colorHex,
                    leadLogo: team?.logoURL(season: Self.currentSeason()))

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

    // MARK: - Live timing (F1's own feed)

    /// The live readout distilled from an F1 live-timing snapshot.
    struct LiveReadout {
        let grandPrix: String     // "Hungary GP"
        let session: String       // "Qualifying" / "Race" / "Practice 2"
        let detail: String        // "Q2 · SC · NOR (McLaren)" / "L32/70 · VER (Red Bull)"
        let flag: RaceFlag?
        let accentHex: String?
        let logo: URL?            // leading driver's constructor mark
        let isRace: Bool
    }

    /// Turn a live snapshot into a readout. Returns nil if the snapshot has no usable session
    /// identity. Callers must have already checked `snapshot.isLive()`. Pure — a tested seam.
    nonisolated static func liveReadout(from snapshot: F1LiveSnapshot,
                                        season: Int = Self.currentSeason()) -> LiveReadout? {
        guard let session = snapshot.sessionName else { return nil }
        let grandPrix = snapshot.countryName.map { "\($0) GP" }
            ?? snapshot.meetingName ?? "Grand Prix"
        let isRace = session.lowercased().contains("race")

        // Leader + constructor, straight from the feed (DriverList carries both).
        let drivers = snapshot.drivers
        let leader = snapshot.leaderNumber.flatMap { drivers[$0] }
        let who = leader.map { entry -> String in
            entry.team.map { "\(entry.tla) (\($0))" } ?? entry.tla
        }

        var parts: [String] = []
        // Races count laps; every other session runs on a clock. Qualifying gets both its phase
        // and the time left in it ("Q3 1:52"), which is the thing you actually glance for.
        if isRace, let lap = snapshot.currentLap {
            parts.append(snapshot.totalLaps.map { "L\(lap)/\($0)" } ?? "L\(lap)")
        } else {
            let phase = snapshot.qualifyingPhase.flatMap {
                session.lowercased().contains("qual") ? "Q\($0)" : nil
            }
            let clock = snapshot.timeRemaining
            if let combined = [phase, clock].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                parts.append(combined)
            }
        }
        if let label = snapshot.flag?.shortLabel { parts.append(label) }
        if let who { parts.append(who) }

        let constructor = leader?.team.map { F1Constructor(name: $0, colorHex: leader?.colour) }
        return LiveReadout(
            grandPrix: grandPrix,
            session: session,
            detail: parts.isEmpty ? "In Progress" : parts.joined(separator: " · "),
            flag: snapshot.flag,
            accentHex: leader?.colour,
            logo: constructor?.logoURL(season: season),
            isRace: isRace)
    }

    /// The season F1's logo CDN is publishing under. Pure — a tested seam.
    nonisolated static func currentSeason(now: Date = Date()) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: now)
    }

    /// Whether an ESPN-derived event is the same session the live feed is reporting.
    nonisolated static func matches(event: SportEvent, live: LiveReadout) -> Bool {
        let suffix = live.isRace ? "-Race" : (live.session.lowercased().contains("qual") ? "-Qual" : nil)
        guard let suffix else { return false }
        return event.id.hasSuffix(suffix)
    }

    /// Overlay live state onto the ESPN session event, keeping its id and date.
    nonisolated static func applyLive(_ live: LiveReadout, to base: SportEvent) -> SportEvent {
        var event = base
        event.state = .live
        event.displayString = "\(live.grandPrix) · \(live.detail)"
        event.menuShort = live.detail
        event.sortPriority = event.isFavorite ? 1000 : 800
        event.flag = live.flag
        event.accentHex = live.accentHex
        event.leadLogo = live.logo
        return event
    }

    /// A standalone event for a live session ESPN hasn't caught up to (practice, or its lagging
    /// F1 status). Not marked favorite — the followed-series promotion handles that.
    nonisolated static func liveEvent(_ live: LiveReadout, league: LeagueID) -> SportEvent {
        SportEvent(
            id: "f1-live-\(live.session)",
            league: league,
            state: .live,
            displayString: "\(live.grandPrix) · \(live.session) · \(live.detail)",
            isFavorite: false,
            sortPriority: 800,
            flag: live.flag,
            menuShort: "\(live.session) · \(live.detail)",
            accentHex: live.accentHex,
            leadLogo: live.logo)
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
