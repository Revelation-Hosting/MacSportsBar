import Foundation

/// Client for **Formula 1's own live timing feed** — the same feed that drives F1's live timing
/// page. It speaks SignalR Core over a WebSocket and, notably, accepts **unauthenticated**
/// connections for the timing topics this app needs. No key, no account, no subscription.
///
/// Why this exists at all: ESPN's F1 data is `gameSource: "scrubbed"` (post-session only), and
/// OpenF1's live tier is a paid re-packaging *of this very feed*. Going to the source keeps
/// MacSportsBar keyless and gets strictly more: live track status (green/yellow/SC/VSC/red),
/// running order, lap count, and the qualifying phase.
///
/// **Connect-per-poll, not a persistent socket.** Each `snapshot()` negotiates, upgrades,
/// subscribes, reads the one completion frame carrying full state, and closes — a fraction of a
/// second. That fits the existing poll loop, avoids long-lived-socket reconnection handling, and
/// keeps us a low-volume, well-behaved client on an undocumented endpoint.
///
/// ⚠️ Two operational realities, both handled by callers:
/// 1. **The snapshot lies between sessions** — it serves the last session's frozen state
///    indefinitely. Never render it without checking `isLive` (see `F1LiveSnapshot`).
/// 2. **Some networks are blocked.** F1 fronts this with an AWS WAF that rejects hosting/VPN
///    egress ranges with a 403. Treat unreachability as normal and degrade to ESPN.
struct F1LiveTimingClient {
    var host = "livetiming.formula1.com"
    var timeout: TimeInterval = 12
    /// F1's own client identifies as the Unity HTTP library; match it.
    var userAgent = "BestHTTP"

    /// The topics we subscribe to — deliberately the minimum the menu bar renders. `CarData.z`
    /// and `Position.z` (car telemetry and track XY) are excluded: they're the only streams that
    /// require a paid F1 TV token, and we don't need them.
    static let topics = [
        "SessionInfo",          // meeting + session identity
        "SessionStatus",        // Started / Aborted / Finished
        "TrackStatus",          // green / yellow / SC / VSC / red
        "LapCount",             // current + total laps (races)
        "DriverList",           // driver → team name + livery colour
        "TimingData",           // running order
        "SessionData",          // qualifying phase (Q1/Q2/Q3)
        "RaceControlMessages",  // safety car / incident text
        "Heartbeat",            // liveness
    ]

    enum ClientError: Error {
        case badStatus(Int)
        case blocked          // WAF/VPN 403 — expected on some networks
        case handshakeFailed
        case noSnapshot
    }

    /// SignalR's record separator: messages are `<json>\u{1e}`, possibly several per frame.
    private static let recordSeparator: Character = "\u{1e}"

    /// Fetch one full state snapshot. Throws `.blocked` when the network can't reach the feed.
    func snapshot(session: URLSession = .shared) async throws -> F1LiveSnapshot {
        let (token, cookie) = try await negotiate(session: session)

        var request = URLRequest(url: URL(string: "wss://\(host)/signalrcore?id=\(token)")!)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.formula1.com", forHTTPHeaderField: "Origin")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        // SignalR Core handshake, then subscribe. Both are single records.
        try await task.send(.string(#"{"protocol":"json","version":1}"# + String(Self.recordSeparator)))
        let subscribe: [String: Any] = [
            "type": 1, "invocationId": "0", "target": "Subscribe", "arguments": [Self.topics],
        ]
        let payload = try JSONSerialization.data(withJSONObject: subscribe)
        try await task.send(.string(String(decoding: payload, as: UTF8.self) + String(Self.recordSeparator)))

        // The reply to invocation "0" is a type-3 completion carrying the whole state object.
        for _ in 0..<12 {
            let message = try await task.receive()
            guard case .string(let text) = message else { continue }
            for record in text.split(separator: Self.recordSeparator) {
                guard let data = record.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                guard object["type"] as? Int == 3, object["invocationId"] as? String == "0" else { continue }
                guard let state = Self.completionState(object) else { throw ClientError.noSnapshot }
                return F1LiveSnapshot(raw: state)
            }
        }
        throw ClientError.noSnapshot
    }

    /// A SignalR completion carries its value under `result`, which F1 sends as either the state
    /// object itself or a single-element array wrapping it. Pure — a tested seam.
    nonisolated static func completionState(_ object: [String: Any]) -> [String: Any]? {
        if let dictionary = object["result"] as? [String: Any] { return dictionary }
        if let array = object["result"] as? [Any] {
            return array.compactMap { $0 as? [String: Any] }.first
        }
        return nil
    }

    /// POST the negotiate endpoint for a connection token, carrying the load-balancer cookies
    /// forward so the WebSocket lands on the same backend.
    private func negotiate(session: URLSession) async throws -> (token: String, cookie: String?) {
        var request = URLRequest(
            url: URL(string: "https://\(host)/signalrcore/negotiate?negotiateVersion=1")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 403 ? ClientError.blocked : ClientError.badStatus(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["connectionToken"] as? String
        else { throw ClientError.handshakeFailed }

        let cookie = (response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Set-Cookie") }
            .map { $0.split(separator: ";").first.map(String.init) ?? $0 }
        return (token, cookie)
    }
}

// MARK: - Snapshot

/// One decoded state snapshot from F1 live timing. Every accessor is defensive: the feed is
/// undocumented and shapes drift, so a missing field degrades the readout rather than failing.
struct F1LiveSnapshot {
    let raw: [String: Any]

    private func topic(_ name: String) -> [String: Any]? { raw[name] as? [String: Any] }

    // MARK: Liveness

    /// The feed's own clock. Between sessions this stays frozen at the last session's end, which
    /// is exactly how we tell "live" from "stale".
    var heartbeat: Date? {
        (topic("Heartbeat")?["Utc"] as? String).flatMap(Self.parseDate)
    }

    /// `Started`, `Aborted`, `Finished`, `Ends`, …
    var sessionStatus: String? { topic("SessionStatus")?["Status"] as? String }
    var sessionStarted: String? { topic("SessionStatus")?["Started"] as? String }

    /// Whether this snapshot describes a session happening **right now**. The heartbeat is the
    /// load-bearing check — the snapshot otherwise serves a finished session's state forever.
    /// Pure — a tested seam.
    func isLive(now: Date = Date(), tolerance: TimeInterval = 120) -> Bool {
        guard let heartbeat, now.timeIntervalSince(heartbeat) <= tolerance else { return false }
        let finished: Set<String> = ["Finished", "Ends"]
        if let sessionStarted, finished.contains(sessionStarted) { return false }
        if let sessionStatus, finished.contains(sessionStatus) { return false }
        return true
    }

    // MARK: Session identity

    var meetingName: String? {
        ((topic("SessionInfo")?["Meeting"] as? [String: Any])?["Name"]) as? String
    }
    var countryName: String? {
        let meeting = topic("SessionInfo")?["Meeting"] as? [String: Any]
        return (meeting?["Country"] as? [String: Any])?["Name"] as? String
    }
    /// `Practice 1`, `Qualifying`, `Race`, `Sprint`…
    var sessionName: String? { topic("SessionInfo")?["Name"] as? String }
    var sessionType: String? { topic("SessionInfo")?["Type"] as? String }

    // MARK: Live state

    var flag: RaceFlag? { RaceFlag(trackStatus: topic("TrackStatus")?["Status"] as? String) }

    var currentLap: Int? { topic("LapCount")?["CurrentLap"] as? Int }
    var totalLaps: Int? { topic("LapCount")?["TotalLaps"] as? Int }

    /// Qualifying phase 1/2/3, from `SessionData`'s series entries (the last one wins).
    var qualifyingPhase: Int? {
        guard let series = topic("SessionData")?["Series"] else { return nil }
        let entries: [[String: Any]]
        if let array = series as? [[String: Any]] { entries = array }
        else if let dictionary = series as? [String: Any] {
            entries = dictionary.values.compactMap { $0 as? [String: Any] }
        } else { return nil }
        return entries.compactMap { $0["QualifyingPart"] as? Int }.last
    }

    /// Driver number → (three-letter code, team, livery hex).
    var drivers: [String: (tla: String, team: String?, colour: String?)] {
        guard let list = topic("DriverList") else { return [:] }
        var result: [String: (String, String?, String?)] = [:]
        for (number, value) in list {
            guard let entry = value as? [String: Any],
                  let tla = entry["Tla"] as? String else { continue }
            result[number] = (tla, entry["TeamName"] as? String, entry["TeamColour"] as? String)
        }
        return result
    }

    /// Driver number currently running P1, from `TimingData.Lines`.
    var leaderNumber: String? {
        guard let lines = topic("TimingData")?["Lines"] as? [String: Any] else { return nil }
        for (number, value) in lines {
            guard let line = value as? [String: Any] else { continue }
            let position = (line["Position"] as? String).flatMap(Int.init) ?? (line["Position"] as? Int)
            if position == 1 { return number }
        }
        return nil
    }

    nonisolated static func parseDate(_ string: String) -> Date? {
        for formatter in isoFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()
}
