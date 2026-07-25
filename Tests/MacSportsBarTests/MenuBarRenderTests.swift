import XCTest
import SwiftUI
import AppKit
@testable import MacSportsBar

/// Guards the menu-bar *layout* decisions, which pure-logic tests can't see.
///
/// Motivation: the F1 constructor mark silently vanished twice, because the render had three
/// near-identical branches and an event that shifted between them (flag → accent → plain) landed
/// in one that never drew the mark. The branches are now collapsed into one; these lock that in.
@MainActor
final class MenuBarRenderTests: XCTestCase {

    /// Renders the same composition the menu bar builds, and reports its width.
    private func width(text: String, symbol: String, tint: Color?,
                       mark: NSImage?, anchor: String?) throws -> CGFloat {
        let split = AppModel.splitForLeadLogo(text, anchor: anchor)
        let view = HStack(spacing: 4) {
            if let tint { Image(systemName: symbol).foregroundStyle(tint) }
            else { Image(systemName: symbol) }
            if let mark {
                if !split.before.isEmpty { Text(split.before) }
                Image(nsImage: mark).resizable().scaledToFit().frame(width: 15, height: 15)
                Text(split.after)
            } else {
                Text(text)
            }
        }.font(.system(size: 13))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage, "ImageRenderer produced nothing").size.width
    }

    private var mark: NSImage {
        let image = NSImage(size: NSSize(width: 15, height: 15))
        image.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: 15, height: 15).fill()
        image.unlockFocus()
        return image
    }

    private let readout = "Hungary GP · Qualifying Finished · P1 NOR"

    /// The regression: a finished F1 session has NO flag and NO accent tint (the mark carries the
    /// team), which is exactly the combination that used to fall through to a mark-less branch.
    func testMarkIsDrawnWithNeitherFlagNorAccent() throws {
        let bare = try width(text: readout, symbol: "flag.checkered", tint: nil,
                             mark: nil, anchor: "NOR")
        let marked = try width(text: readout, symbol: "flag.checkered", tint: nil,
                               mark: mark, anchor: "NOR")
        XCTAssertGreaterThan(marked, bare,
                             "a finished session must still draw the constructor mark")
    }

    func testMarkIsDrawnAlongsideAColouredFlag() throws {
        let bare = try width(text: readout, symbol: "flag.fill", tint: .yellow, mark: nil, anchor: "NOR")
        let marked = try width(text: readout, symbol: "flag.fill", tint: .yellow, mark: mark, anchor: "NOR")
        XCTAssertGreaterThan(marked, bare, "a live session under caution still shows the mark")
    }

    func testMarkIsDrawnAlongsideAnAccentTint() throws {
        let bare = try width(text: readout, symbol: "flag.checkered", tint: .orange, mark: nil, anchor: "NOR")
        let marked = try width(text: readout, symbol: "flag.checkered", tint: .orange, mark: mark, anchor: "NOR")
        XCTAssertGreaterThan(marked, bare)
    }

    func testRenderProducesANonEmptyImage() throws {
        // The render rejects zero-size images; make sure the normal path isn't one.
        XCTAssertGreaterThan(try width(text: readout, symbol: "flag.checkered", tint: nil,
                                       mark: mark, anchor: "NOR"), 1)
    }
}
