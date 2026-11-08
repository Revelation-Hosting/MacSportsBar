import XCTest
import AppKit
import Combine
@testable import MacSportsBar

/// The dropdown's data holds still while a menu is open. The regression it guards: every poll
/// republished the menu, which closed the league flyout the user was hovering.
@MainActor
final class MenuPresenterTests: XCTestCase {

    private let nfl = LeagueID(sport: "football", league: "nfl", displayName: "NFL")
    // Its own center, so the test never posts AppKit's menu notifications process-wide.
    private let center = NotificationCenter()

    private func layout(_ ids: String...) -> MenuLayout {
        MenuLayout(digest: [], events: ids.map {
            SportEvent(id: $0, league: nfl, state: .live, displayString: $0,
                       isFavorite: false, sortPriority: 0)
        }, leagueOrder: ["nfl"])
    }

    private func shownIDs(_ presenter: MenuPresenter) -> [String] {
        presenter.layout.leagues.flatMap(\.live).map(\.id)
    }

    func testALayoutShowsAtOnceWhileNoMenuIsOpen() {
        let presenter = MenuPresenter(notificationCenter: center)
        presenter.show(layout("a"))
        XCTAssertEqual(shownIDs(presenter), ["a"])
    }

    func testAPollWhileTheMenuIsOpenWaitsForItToClose() {
        let presenter = MenuPresenter(notificationCenter: center)
        presenter.show(layout("before"))
        var publishes = 0
        let watch = presenter.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }

        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        presenter.show(layout("first poll"))
        presenter.show(layout("second poll"))
        XCTAssertEqual(publishes, 0, "any publish rebuilds the menu under the cursor")
        XCTAssertEqual(shownIDs(presenter), ["before"])

        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertEqual(shownIDs(presenter), ["second poll"], "the newest layout lands on close")
        XCTAssertEqual(publishes, 1)
    }

    func testClosingWithNothingPendingDoesNotPublish() {
        let presenter = MenuPresenter(notificationCenter: center)
        presenter.show(layout("a"))
        var publishes = 0
        let watch = presenter.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }

        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertEqual(publishes, 0)

        presenter.show(layout("b"))
        XCTAssertEqual(shownIDs(presenter), ["b"], "back to showing at once after the menu closes")
    }
}
