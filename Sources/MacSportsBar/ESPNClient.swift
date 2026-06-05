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

    /// GET `<base>/<sport>/<league>/scoreboard` and decode it as `T`.
    func scoreboard<T: Decodable>(sport: String, league: String, as type: T.Type) async throws -> T {
        let url = baseURL
            .appendingPathComponent(sport)
            .appendingPathComponent(league)
            .appendingPathComponent("scoreboard")

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
