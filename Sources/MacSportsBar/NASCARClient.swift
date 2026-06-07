import Foundation

/// Thin HTTP chokepoint for NASCAR's live timing feed — the live lap/stage/flag/running-order
/// telemetry that ESPN simply doesn't have (ESPN holds no NASCAR media rights, so its NASCAR
/// data is `basic/manual` with no laps, stages, or flags — see `RacingAdapter`).
///
/// Unlike ESPN's undocumented endpoints, **NASCAR publishes a Swagger 2.0 spec** for this feed
/// at https://feed.nascar.com/swagger/docs/v1 — every field name and enum in `NASCARLiveFeed`
/// below is taken straight from it (the `cf.nascar.com` host is the CDN cache of that API).
/// Still treat it as best-effort and decode defensively: it reflects the *currently active* run
/// and sits on the last completed race between events.
struct NASCARClient {
    /// CDN-cached live feed for the currently active run (practice / qualifying / race).
    var liveFeedURL = URL(string: "https://cf.nascar.com/live/feeds/live-feed.json")!
    var timeout: TimeInterval = 10
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    enum ClientError: Error { case badStatus(Int) }

    /// GET the live feed and decode it. Keys are snake_case (`laps_to_go`, `vehicle_number`),
    /// so the decoder converts them to the camelCase properties below.
    func liveFeed() async throws -> NASCARLiveFeed {
        var request = URLRequest(url: liveFeedURL)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NASCARLiveFeed.self, from: data)
    }
}

// MARK: - Live-feed model (subset of feed.nascar.com/swagger `LiveFeed`; everything optional)

/// Decoded NASCAR live feed. Field names + enums mirror the official Swagger `LiveFeed`/`Vehicle`
/// models; only the fields the app uses are kept, all optional for defensive decoding.
struct NASCARLiveFeed: Decodable {
    let lapNumber: Int?
    let flagState: Int?          // 1-Green 2-Yellow 3-Red 4-Finish 6-Stop 8-Warm Up 9-Not Active
    let raceId: Int?
    let lapsInRace: Int?
    let lapsToGo: Int?
    let runName: String?         // e.g. "FireKeepers Casino 400"
    let runType: Int?            // 1-Practice 2-Qualifying 3-Race
    let seriesId: Int?           // 1-Cup 2-XFINITY 3-Truck
    let trackName: String?
    let numberOfLeadChanges: Int?
    let numberOfCautionSegments: Int?
    let stage: Stage?
    let vehicles: [Vehicle]?

    struct Stage: Decodable {
        let stageNum: Int?
        let finishAtLap: Int?
        let lapsInStage: Int?
    }

    struct Vehicle: Decodable {
        let runningPosition: Int?     // race rank (1 = leader)
        let vehicleNumber: String?
        let vehicleManufacturer: String?  // Chv / Tyt / Frd / Dge
        let sponsorName: String?
        let status: Int?              // 1-Running 2-BTW 3-Out
        let driver: Driver?
    }

    struct Driver: Decodable {
        let fullName: String?
        let firstName: String?
        let lastName: String?
    }
}
