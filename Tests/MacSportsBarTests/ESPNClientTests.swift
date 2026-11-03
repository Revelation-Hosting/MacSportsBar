import XCTest
@testable import MacSportsBar

/// Tests for `ESPNClient` URL building — the seam that carries per-league scoreboard
/// parameters (college football's `groups=80`) and the `/teams` page-size override.
final class ESPNClientTests: XCTestCase {

    private let client = ESPNClient()
    private var base: String { client.baseURL.absoluteString }

    func testPlainResourceHasNoQuery() {
        let url = client.url(sport: "basketball", league: "nba", "scoreboard")
        XCTAssertEqual(url.absoluteString, "\(base)/basketball/nba/scoreboard")
    }

    func testDatesComesFirstThenExtraQuery() {
        let url = client.url(
            sport: "football", league: "college-football", "scoreboard", dates: "20260912",
            query: [URLQueryItem(name: "groups", value: "80")])
        XCTAssertEqual(url.absoluteString,
                       "\(base)/football/college-football/scoreboard?dates=20260912&groups=80")
    }

    func testExtraQueryWithoutDates() {
        let url = client.url(sport: "football", league: "college-football", "teams",
                             query: [URLQueryItem(name: "limit", value: "1000")])
        XCTAssertEqual(url.absoluteString, "\(base)/football/college-football/teams?limit=1000")
    }

    /// ESPN's default college-football board is a Top-25-ish slice (~24 games on a Saturday vs
    /// ~85 for the FBS group), so a favorite outside the rankings never appeared. The catalog
    /// entry must ask for the FBS group; the pro leagues' default boards are already complete.
    func testCollegeFootballRequestsTheFBSGroup() throws {
        let ncaaf = try XCTUnwrap(LeagueCatalog.all.first { $0.id == "college-football" })
        let groups = ncaaf.league.scoreboardQuery.first { $0.name == "groups" }?.value
        XCTAssertEqual(groups, "80")

        let nfl = try XCTUnwrap(LeagueCatalog.all.first { $0.id == "nfl" })
        XCTAssertTrue(nfl.league.scoreboardQuery.isEmpty)
    }

    /// The men's board has the same trap (9 games on a night with 69), and the group has to
    /// survive the adapter too: a fetch that drops `scoreboardQuery` silently gets the slice.
    func testCollegeBasketballFetchRequestsDivisionI() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let client = ESPNClient(session: URLSession(configuration: config))

        let ncaam = try XCTUnwrap(LeagueCatalog.all.first { $0.id == "mens-college-basketball" })
        _ = try await ncaam.makeAdapter(.none).fetch(using: client, dates: "20261110")

        let url = try XCTUnwrap(RecordingURLProtocol.lastURL)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "groups" }?.value, "50")
        XCTAssertEqual(items.first { $0.name == "dates" }?.value, "20261110")
    }
}

/// Records the requested URL and answers with an empty scoreboard, so no test touches the network.
private final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"events":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
