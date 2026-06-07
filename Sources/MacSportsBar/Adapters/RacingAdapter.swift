import Foundation

/// Decodes ESPN's NASCAR Cup scoreboard JSON (a *field* shape) into one compact string per
/// race: short track/race name + the current leader (or winner / scheduled time).
///
/// ⚠️ Degraded by necessity, not just by design. Investigated live during the 2026 Michigan
/// Cup race: ESPN does NOT hold NASCAR media rights (the 2025+ deal is FOX/Amazon/TNT/NBC),
/// so its NASCAR data is `gameSource: basic/manual` with `liveAvailable: false` — laggy and
/// sparse. The race stayed `STATUS_SCHEDULED` for ~35 min past the green flag, the live
/// detail is a generic "In Progress" (no lap/stage), the `summary` endpoint 502s, and there
/// is no caution/flag field. So `… · L245/400 · St3` telemetry is simply NOT obtainable from
/// ESPN for NASCAR. The running order (leader = `order == 1`) is reliable; car number +
/// manufacturer live in the core API per-competitor `$ref` (`vehicle`). Real lap/stage/flag
/// data would require a non-ESPN NASCAR timing source — a separate, future effort.
struct RacingAdapter: SportAdapter {
    let league: LeagueID
    /// Lowercased favorite driver names. Empty = no favorites.
    let favorites: Set<String>
    /// NASCAR's own live timing feed — the lap/stage/flag telemetry ESPN lacks. Best-effort:
    /// when it shows a live Cup race we enrich the ESPN event; otherwise ESPN is the baseline.
    var nascar = NASCARClient()

    func fetch(using client: ESPNClient, dates: String?) async throws -> [SportEvent] {
        let payload = try await client.scoreboard(
            sport: league.sport, league: league.league, dates: dates, as: Scoreboard.self
        )
        let rawEvents = payload.events ?? []
        var events = rawEvents.map(map)

        // Enrich the day's ESPN race with NASCAR's live feed (the lap/stage/flag telemetry +
        // the actual winner, since ESPN lags badly — it still says "In Progress" minutes after
        // the checkered). Staleness guard: an *active* race is always today's, but the feed sits
        // on the *last* race between events, so only trust a *finished* feed when ESPN isn't
        // still showing today's race as "pre" (a future race with the feed on last week's finish).
        guard dates == nil,
              let feed = try? await nascar.liveFeed(),
              let live = Self.liveReadout(from: feed),
              let idx = events.indices.first else { return events }
        if live.finished, case .pre = events[idx].state { return events }

        let short = shortRace(rawEvents[idx].name ?? rawEvents[idx].shortName ?? "Race")
        events[idx] = mergeLive(into: events[idx], short: short, live: live)
        return events
    }

    // MARK: - Mapping

    /// Maps one race into a `SportEvent`. Pure — the seam the formatting tests exercise. A
    /// scheduled race has no competitors yet, which is fine (the `pre` branch ignores them).
    func map(_ event: Scoreboard.Event) -> SportEvent {
        let short = shortRace(event.name ?? event.shortName ?? "Race")
        let competitors = event.competitions?.first?.competitors ?? []
        let leader = competitors.first(where: { $0.order == 1 }) ?? competitors.first
        let leaderName = leader.map { Self.lastName($0.athlete?.displayName ?? $0.athlete?.shortName ?? "") }
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
    static func lastName(_ full: String) -> String {
        let parts = full.split(separator: " ").map(String.init)
        guard let last = parts.last else { return full }
        let suffixes: Set<String> = ["Jr.", "Sr.", "Jr", "Sr", "II", "III", "IV"]
        if suffixes.contains(last), parts.count >= 2 { return parts[parts.count - 2] }
        return last
    }

    // MARK: - NASCAR live feed (the real lap/stage/flag telemetry)

    /// The live readout derived purely from NASCAR's feed. Pure — the seam the tests exercise.
    struct LiveReadout {
        let detail: String       // "L55/200 · St2 10/75 · #45 Reddick" (or "#45 Reddick won" at the finish)
        let flag: RaceFlag?
        let leaderName: String?  // surname, for favorite matching
        let finished: Bool       // 4-Finish or laps_to_go == 0
    }

    /// Build the live readout from the feed, or nil when it isn't a live/finished **Cup race**
    /// (e.g. flag 9-Not Active between sessions, or a practice/Xfinity run) — then ESPN's
    /// schedule baseline stands. Pure (no I/O), per the official feed.nascar.com/swagger model.
    nonisolated static func liveReadout(from feed: NASCARLiveFeed) -> LiveReadout? {
        guard feed.seriesId == 1, feed.runType == 3 else { return nil }  // Cup races only
        let rawFlag = RaceFlag(flagState: feed.flagState)
        // A completed race flickers flag 4 (Finish) for seconds, then sits on 9 (Not Active)
        // with laps_to_go 0 — treat either as finished. A 9 that *isn't* a finish (between
        // sessions, laps_to_go > 0) → nil, so ESPN shows the schedule.
        let finished = rawFlag == .checkered || (feed.lapsToGo ?? -1) == 0
        guard rawFlag != nil || finished else { return nil }

        let leader = (feed.vehicles ?? []).min {
            ($0.runningPosition ?? .max) < ($1.runningPosition ?? .max)
        }
        let surname = leader?.driver?.fullName.map(lastName).flatMap { $0.isEmpty ? nil : $0 }
        let leaderTag: String? = surname.map { name in
            leader?.vehicleNumber.map { "#\($0) \(name)" } ?? name
        }

        let detail: String
        let flag: RaceFlag?
        if finished {
            detail = leaderTag.map { "\($0) won" } ?? "Final"
            flag = .checkered                                // checkered glyph at the finish
        } else if rawFlag == .warmup {
            detail = leaderTag.map { "Pace · \($0)" } ?? "Pace laps"
            flag = rawFlag
        } else {
            var parts: [String] = []
            if let lap = feed.lapNumber, let total = feed.lapsInRace { parts.append("L\(lap)/\(total)") }
            if let stage = Self.stageLabel(feed.stage, lap: feed.lapNumber) { parts.append(stage) }
            if let leaderTag { parts.append(leaderTag) }
            detail = parts.isEmpty ? "In Progress" : parts.joined(separator: " · ")
            flag = rawFlag
        }
        return LiveReadout(detail: detail, flag: flag, leaderName: surname, finished: finished)
    }

    /// "St2 10/75" — stage number + laps into the current stage. The feed gives the stage's
    /// `finishAtLap` + `lapsInStage`, so the stage's start lap is `finishAtLap - lapsInStage`
    /// and laps-into-stage is `lap - start`. Falls back to "St2" when that can't be computed or
    /// the lap is out of range (e.g. a green-white-checkered finish running past the stage
    /// length). Pure — a tested seam.
    nonisolated static func stageLabel(_ stage: NASCARLiveFeed.Stage?, lap: Int?) -> String? {
        guard let num = stage?.stageNum else { return nil }
        if let lap, let total = stage?.lapsInStage, let finish = stage?.finishAtLap, total > 0 {
            let into = lap - (finish - total)
            if (1...total).contains(into) { return "St\(num) \(into)/\(total)" }
        }
        return "St\(num)"
    }

    /// Merge the live NASCAR readout onto the day's ESPN race event (keeping its id/date/league),
    /// as a live race or — at the checkered — a final with the winner.
    private func mergeLive(into base: SportEvent, short: String, live: LiveReadout) -> SportEvent {
        let isFav = base.isFavorite || favoriteMatches(live.leaderName)
        var event = base
        event.state = live.finished ? .final : .live
        event.displayString = "\(short) · \(live.detail)"
        // When the bar is tight, drop the track name (the flag glyph already says NASCAR) before
        // clipping the lap/stage/leader.
        event.menuShort = live.detail
        event.isFavorite = isFav
        event.sortPriority = live.finished ? (isFav ? 300 : 100) : (isFav ? 1000 : 800)
        event.flag = live.flag
        return event
    }

    /// Whether a driver surname matches a favorite token (free-form, lowercased substring).
    private func favoriteMatches(_ name: String?) -> Bool {
        guard !favorites.isEmpty, let name = name?.lowercased(), !name.isEmpty else { return false }
        return favorites.contains { name == $0 || name.contains($0) }
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
