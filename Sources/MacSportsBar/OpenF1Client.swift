import Foundation

/// A Formula 1 constructor (team) as the menu bar needs it: the name to print and the team's
/// livery colour to tint the glyph with.
struct F1Constructor: Equatable {
    /// e.g. `McLaren`, `Red Bull Racing`.
    let name: String
    /// `RRGGBB` hex, no leading `#` — OpenF1's `team_colour`.
    let colorHex: String?
}

/// Thin client for the **OpenF1** API (https://openf1.org), used only for what its *free* tier
/// covers: the driver → constructor mapping. ESPN carries F1 sessions and classifications but no
/// team data at all (`vehicle` and `statistics` are empty on every F1 competitor), so this fills
/// the one gap.
///
/// ⚠️ **Deliberately historical-only.** OpenF1's free tier excludes live data: anything from a
/// session in progress — or ended less than 30 minutes ago — requires a paid subscription. This
/// client therefore never asks for a live session; it reads the driver list from the most recent
/// *comfortably finished* session, which is stable for a whole season and cached for hours. That
/// keeps MacSportsBar keyless and free, at the cost of no live F1 telemetry (see `README`).
///
/// Data licensing differs from the rest of the app: OpenF1 is CC BY-NC-SA 4.0 and is an
/// unofficial, community-run project not affiliated with Formula 1.
struct OpenF1Client {
    var baseURL = URL(string: "https://api.openf1.org/v1")!
    var timeout: TimeInterval = 10
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    enum ClientError: Error {
        case badStatus(Int)
        case noFinishedSession
    }

    /// Free-tier safety margin: OpenF1 classifies a session as "live" (paid) until 30 minutes
    /// after it ends, so only read sessions that finished comfortably before that.
    static let historicalMargin: TimeInterval = 45 * 60

    /// Build `lowercased driver surname → constructor`, from the most recent finished session.
    /// Two requests, and the caller caches the result for hours — well inside OpenF1's free
    /// budget of 30 requests/minute.
    func constructorsByLastName(now: Date = Date()) async throws -> [String: F1Constructor] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let sessions: [Session] = try await get("sessions", query: ["year": "\(year)"])
        guard let key = Self.newestHistoricalSessionKey(in: sessions, now: now) else {
            throw ClientError.noFinishedSession
        }
        let drivers: [Driver] = try await get("drivers", query: ["session_key": "\(key)"])
        return Self.constructorMap(from: drivers)
    }

    /// The newest session that ended long enough ago to be free (see `historicalMargin`).
    /// Pure — a tested seam.
    nonisolated static func newestHistoricalSessionKey(in sessions: [Session], now: Date) -> Int? {
        let cutoff = now.addingTimeInterval(-historicalMargin)
        return sessions
            .compactMap { s -> (Int, Date)? in
                guard let key = s.sessionKey, let end = s.endDate, end < cutoff else { return nil }
                return (key, end)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Index drivers by lowercased surname (ESPN prints "Lando Norris"; OpenF1 gives
    /// `last_name: "Norris"`), skipping entries with no usable team. Pure — a tested seam.
    nonisolated static func constructorMap(from drivers: [Driver]) -> [String: F1Constructor] {
        var map: [String: F1Constructor] = [:]
        for driver in drivers {
            guard let team = driver.teamName, !team.isEmpty,
                  let last = driver.lastName?.lowercased(), !last.isEmpty else { continue }
            map[last] = F1Constructor(name: team, colorHex: driver.teamColour)
        }
        return map
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> [T] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw ClientError.badStatus(-1) }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        // A 429 comes back as nginx's HTML error page *labelled* application/json, so the status
        // has to be checked before decoding or the JSON decoder throws something misleading.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode([T].self, from: data)
    }
}

// MARK: - Raw JSON (defensive: everything optional)

extension OpenF1Client {
    struct Session: Decodable {
        let sessionKey: Int?
        let dateEnd: String?

        private enum CodingKeys: String, CodingKey {
            case sessionKey = "session_key"
            case dateEnd = "date_end"
        }

        /// OpenF1 stamps offsets (`2026-07-24T16:00:00+00:00`), which the ISO8601 parser handles.
        var endDate: Date? { dateEnd.flatMap(OpenF1Client.parseDate) }
    }

    struct Driver: Decodable {
        let lastName: String?
        let nameAcronym: String?
        let teamName: String?
        let teamColour: String?

        private enum CodingKeys: String, CodingKey {
            case lastName = "last_name"
            case nameAcronym = "name_acronym"
            case teamName = "team_name"
            case teamColour = "team_colour"
        }
    }

    /// OpenF1 mixes whole-second and fractional-second timestamps, so try both.
    nonisolated static func parseDate(_ string: String) -> Date? {
        for formatter in isoFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()
}

/// Process-wide cache for the constructor map. `AppModel.adapters` is a *computed* property, so a
/// fresh adapter (and client) is built on every poll tick — per-instance caching would never
/// survive. The driver→team mapping changes at most a couple of times a season, so a long TTL
/// keeps this to a handful of OpenF1 requests per day.
actor OpenF1ConstructorDirectory {
    static let shared = OpenF1ConstructorDirectory()

    private var cached: [String: F1Constructor] = [:]
    private var fetchedAt: Date?
    private let client = OpenF1Client()
    private let ttl: TimeInterval = 6 * 3600

    /// Cached constructors, refreshing at most every `ttl`. Never throws: on failure the previous
    /// map (or an empty one) is returned so F1 degrades to driver names without a team.
    func constructors(now: Date = Date()) async -> [String: F1Constructor] {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < ttl, !cached.isEmpty { return cached }
        guard let fresh = try? await client.constructorsByLastName(now: now), !fresh.isEmpty else {
            return cached
        }
        cached = fresh
        self.fetchedAt = now
        return cached
    }
}
