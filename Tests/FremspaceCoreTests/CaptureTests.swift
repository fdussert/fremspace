import XCTest
import CoreGraphics
@testable import FremspaceCore

final class CaptureTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 3360, height: 1890)

    private func window(_ id: UInt32, _ bundle: String, minimized: Bool = false, fullScreen: Bool = false) -> WindowInfo {
        WindowInfo(id: id, pid: 1, bundleID: bundle, title: "", profile: nil, isStandard: true,
                   isMinimized: minimized, isFullScreen: fullScreen)
    }

    func testCaptureRoundsToCleanFractions() {
        let layout = capture(windows: [
            (window(1, "com.microsoft.VSCode"), CGRect(x: 8, y: 8, width: 2004, height: 1874)),
            (window(2, "com.brave.Browser"), CGRect(x: 2020, y: 8, width: 1332, height: 1874)),
        ], visible: visible)
        XCTAssertEqual(layout.slots.map(\.rect), [UnitRect(x: 0, y: 0, w: 0.6, h: 1), UnitRect(x: 0.6, y: 0, w: 0.4, h: 1)])
        XCTAssertEqual(layout.slots.map(\.rule.bundleID), ["com.microsoft.VSCode", "com.brave.Browser"])
        XCTAssertEqual(layout.slots.map(\.id), ["vscode", "browser"])
    }

    func testFreeFormCaptureKeepsWindowsWhereTheyAreOverOneAnother() {
        // The mail window, front, with Messages under it and showing on its left.
        let layout = captureFreeForm(windows: [
            (window(1, "com.apple.mail"), CGRect(x: 840, y: 189, width: 1680, height: 1512)),
            (window(2, "com.apple.MobileSMS"), CGRect(x: 336, y: 378, width: 1008, height: 945)),
            (window(3, "com.apple.finder", minimized: true), CGRect(x: 0, y: 0, width: 1000, height: 1000)),
        ], visible: visible)
        XCTAssertTrue(layout.freeForm)
        // Front to back, where they were, to a thousandth of the display; nothing snapped or dropped.
        XCTAssertEqual(layout.slots.map(\.rule.bundleID), ["com.apple.mail", "com.apple.MobileSMS"])
        XCTAssertEqual(layout.slots.map(\.rect), [UnitRect(x: 0.25, y: 0.1, w: 0.5, h: 0.8), UnitRect(x: 0.1, y: 0.2, w: 0.3, h: 0.5)])
        // Not locked: the windows go back there when Fremspace places them again, and may be moved meanwhile.
        XCTAssertEqual(layout.slots.map(\.locked), [false, false])
        // Overlapping slots are what it is for: it can be saved.
        XCTAssertNil(isValid(layout))
        var tiled = layout
        tiled.freeForm = false
        XCTAssertNotNil(isValid(tiled))
        // A window is put back exactly where it was: no gap taken off its frame.
        let frames = slotFrames(layout: layout, focus: nil, visible: visible, gap: 8)
        XCTAssertEqual(frames["mail"], CGRect(x: 840, y: 189, width: 1680, height: 1512))
        XCTAssertEqual(frames["mobilesms"], CGRect(x: 336, y: 378, width: 1008, height: 945))
    }

    func testFreeFormCaptureKeepsWhatShowsOfAWindowAndSharesASlotOnlyAtTheSamePlace() {
        let frame = CGRect(x: 336, y: 378, width: 1008, height: 945)
        let layout = captureFreeForm(windows: [
            (window(1, "com.brave.Browser"), frame),
            (window(2, "com.brave.Browser"), frame),
            (window(3, "com.brave.Browser"), frame.offsetBy(dx: 336, dy: 0)),
            // Half off the right edge: kept as far as it shows. Wholly off the display: not kept.
            (window(4, "com.apple.Notes"), CGRect(x: 3024, y: 0, width: 672, height: 945)),
            (window(5, "com.apple.Notes"), CGRect(x: 4000, y: 0, width: 600, height: 600)),
        ], visible: visible)
        XCTAssertEqual(layout.slots.map(\.id), ["browser", "browser-2", "notes"])
        XCTAssertEqual(layout.slots[2].rect, UnitRect(x: 0.9, y: 0, w: 0.1, h: 0.5))
    }

    func testAFreeFormLayoutHasNoNeighboursAndIsReadBackFromItsFile() throws {
        let layout = captureFreeForm(windows: [
            (window(1, "com.apple.mail"), CGRect(x: 0, y: 0, width: 1680, height: 1890)),
            (window(2, "com.apple.MobileSMS"), CGRect(x: 1680, y: 0, width: 1680, height: 1890)),
        ], visible: visible)
        // Side by side as they are, removing one leaves the other at its place, and no edge is dragged.
        XCTAssertEqual(remove(layout, slot: "mail").slots.map(\.rect), [UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)])
        XCTAssertTrue(dividers(layout).isEmpty)
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(Layout.self, from: data)
        XCTAssertEqual(back, layout)
        // A layout cut out of the screen is written as before, without the word.
        let tiled = try JSONEncoder().encode(Layout(slots: layout.slots))
        XCTAssertFalse(String(decoding: tiled, as: UTF8.self).contains("freeForm"))
        let old = try JSONDecoder().decode(Layout.self, from: tiled)
        XCTAssertFalse(old.freeForm)
    }

    func testCaptureStacksSameAppSameRect() {
        let frame = CGRect(x: 8, y: 8, width: 3344, height: 1874)
        let layout = capture(windows: [(window(1, "com.brave.Browser"), frame), (window(2, "com.brave.Browser"), frame)], visible: visible)
        XCTAssertEqual(layout.slots.count, 1)
    }

    func testCaptureSkipsUnmanageableAndNeverOverlaps() {
        let layout = capture(windows: [
            (window(1, "com.apple.finder", minimized: true), CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            (window(2, "com.apple.Safari", fullScreen: true), visible),
            (window(3, "com.microsoft.VSCode"), CGRect(x: 8, y: 8, width: 2004, height: 1874)),
            (window(4, "com.sublimetext.4"), CGRect(x: 1000, y: 8, width: 2352, height: 1874)),
        ], visible: visible)
        XCTAssertEqual(layout.slots.map(\.rule.bundleID), ["com.microsoft.VSCode"])
    }
}
