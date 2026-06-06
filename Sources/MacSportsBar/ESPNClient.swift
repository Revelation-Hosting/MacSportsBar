import Foundation

/// Thin HTTP chokepoint for ESPN's undocumented scoreboard API. Timeouts, headers, and a
/// future base-URL swap (e.g. a self-hosted caching proxy) live here so adapters don't
/// each reinvent networking.
///
/// ⚠️ These endpoints are unofficial and unsupported — they can change shape or disappear
/// without notice. Adapters MUST decode defensively and degrade rather than crash.
struct ESPNClient {
    /// Base for the site scoreboard API: `<base>/<sport>/<league>/scoreboard`.
    var baseURL = URL(string: "https://site.api.espn.com/apis/site/v2/sports")!
    var timeout: TimeInterval = 15
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum ClientError: Error {
        case badStatus(Int)
    }

    /// GET `<base>/<sport>/<league>/<resource>` and decode it as `T`. `dates` (YYYYMMDD) adds
    /// the `?dates=` query to fetch a specific day instead of the default (today).
    func resource<T: Decodable>(
        sport: String, league: String, _ resource: String, dates: String? = nil, as type: T.Type
    ) async throws -> T {
        var url = baseURL
            .appendingPathComponent(sport)
            .appendingPathComponent(league)
            .appendingPathComponent(resource)
        if let dates {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "dates", value: dates)]
            url = components?.url ?? url
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// GET `<base>/<sport>/<league>/scoreboard` and decode it as `T`. `dates` (YYYYMMDD)
    /// selects a specific day; nil fetches the default (today).
    func scoreboard<T: Decodable>(
        sport: String, league: String, dates: String? = nil, as type: T.Type
    ) async throws -> T {
        try await resource(sport: sport, league: league, "scoreboard", dates: dates, as: type)
    }
}
