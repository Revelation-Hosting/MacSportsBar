import XCTest
@testable import MacSportsBar

/// Tests for `AppModel`'s pure display helpers: menu-bar truncation and cycle-candidate
/// selection. Both are `nonisolated static`, so no `AppModel` instance (and no polling) is
/// needed.
final class AppModelTests: XCTestCase {

    // MARK: - truncate

    func testTruncateLeavesShortStringsUnchanged() {
        XCTAssertEqual(AppModel.truncate("Hello", limit: 40), "Hello")
    }

    func testTruncateLeavesStringAtLimitUnchanged() {
        let s = String(repeating: "a", count: 40)
        XCTAssertEqual(AppModel.truncate(s, limit: 40), s)
    }

    func testTruncateOverLimitClipsAndAddsEllipsis() {
        let s = String(repeating: "a", count: 50)
        let out = AppModel.truncate(s, limit: 40)
        XCTAssertEqual(out.count, 40, "result must fit exactly within the limit")
        XCTAssertEqual(out, String(repeating: "a", count: 39) + "…")
    }

    func testTruncateFloorsTinyLimitsAtEight() {
        let out = AppModel.truncate("abcdefghijklmnop", limit: 3)  // 3 is floored to 8
        XCTAssertEqual(out.count, 8)
        XCTAssertEqual(out, "abcdefg…")
    }

    func testTruncateCountsCharactersNotBytes() {
        // Grapheme clusters: each basketball is one Character, so prefix() must not split it.
        let s = String(repeating: "🏀", count: 20)
        let out = AppModel.truncate(s, limit: 10)
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out, String(repeating: "🏀", count: 9) + "…")
    }

    // MARK: - candidates(from:)

    func testCandidatesPrefersLiveGames() {
        let input = [
            event(id: "live1", state: .live, favorite: false),
            event(id: "favPre", state: .pre(startDate: nil), favorite: true),
            event(id: "live2", state: .live, favorite: false),
            event(id: "final", state: .final, favorite: false),
        ]
        XCTAssertEqual(AppModel.candidates(from: input).map(\.id), ["live1", "live2"])
    }

    func testCandidatesFallBackToFavoritesWhenNoLive() {
        let input = [
            event(id: "fav1", state: .pre(startDate: nil), favorite: true),
            event(id: "plain", state: .pre(startDate: nil), favorite: false),
            event(id: "fav2", state: .final, favorite: true),
        ]
        XCTAssertEqual(AppModel.candidates(from: input).map(\.id), ["fav1", "fav2"])
    }

    func testCandidatesFallBackToTopOneWhenNoLiveNoFavorites() {
        let input = [
            event(id: "top", state: .pre(startDate: nil), favorite: false),
            event(id: "next", state: .final, favorite: false),
        ]
        XCTAssertEqual(AppModel.candidates(from: input).map(\.id), ["top"])
    }

    func testCandidatesEmptyInputYieldsEmpty() {
        XCTAssertTrue(AppModel.candidates(from: []).isEmpty)
    }

    // MARK: - Helpers

    private func event(id: String, state: SportEvent.State, favorite: Bool) -> SportEvent {
        SportEvent(
            id: id, state: state, displayString: id, isFavorite: favorite, sortPriority: 0
        )
    }
}
