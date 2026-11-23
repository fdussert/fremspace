import XCTest
import CoreGraphics
@testable import FremspaceCore

final class DrawerGeometryTests: XCTestCase {
    // The owner's desk in AX coordinates.
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let leftDell = CGRect(x: 1512, y: -589, width: 3360, height: 1890)
    private let rightDell = CGRect(x: 4872, y: -589, width: 3360, height: 1890)
    private let edge = CGRect(x: 1950, y: -1309, width: 2560, height: 720)
    private let halves = DrawerLayout(slots: [
        DrawerSlot(id: "top", rect: UnitRect(x: 0, y: 0, w: 1, h: 0.5)),
        DrawerSlot(id: "bottom", rect: UnitRect(x: 0, y: 0.5, w: 1, h: 0.5)),
    ])

    func testDrawerZoneAndFrames() {
        let d = DrawerSpec(edge: .left, size: 0.375, layout: halves)
        XCTAssertEqual(drawerZone(d, visible: rightDell), CGRect(x: 4872, y: -589, width: 1260, height: 1890))
        let f = drawerFrames(d, visible: rightDell, gap: 8)
        XCTAssertEqual(f["top"], CGRect(x: 4880, y: -581, width: 1244, height: 933))
        XCTAssertEqual(f["bottom"], CGRect(x: 4880, y: 360, width: 1244, height: 933))
        let r = DrawerSpec(edge: .right, size: 0.375, layout: halves)
        XCTAssertEqual(drawerZone(r, visible: rightDell), CGRect(x: 6972, y: -589, width: 1260, height: 1890))
    }

    func testTwoDrawersShareOneSetOfSlotKeys() {
        let left = DrawerSpec(edge: .left, size: 0.375, layout: halves)
        let right = DrawerSpec(edge: .right, size: 0.25, layout: halves)
        let f = drawerFrames([left, right], visible: rightDell, gap: 8)
        XCTAssertEqual(f["left.top"], CGRect(x: 4880, y: -581, width: 1244, height: 933))
        XCTAssertEqual(f["right.bottom"]?.maxX, 8224)
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(drawer(ofSlotKey: "right.bottom", in: [left, right])?.edge, .right)
        XCTAssertNil(drawer(ofSlotKey: "top", in: [left, right]))
    }

    func testOwnersDeskFreeSides() {
        XCTAssertEqual(freeSides(of: rightDell, others: [builtIn, leftDell, edge]), [.right, .top, .bottom])
        XCTAssertEqual(freeSides(of: leftDell, others: [builtIn, rightDell, edge]), [.bottom])
    }

    func testParkSideFollowsTheFallbackOrder() {
        XCTAssertEqual(parkSide(for: .right, free: [.right, .top, .bottom]), .right)
        // A left or right side hides a window down to 1 pt; the bottom keeps 32-52 pt visible
        // (second spike), so the opposite side comes before the bottom.
        XCTAssertEqual(parkSide(for: .left, free: [.right, .top, .bottom]), .right)
        XCTAssertEqual(parkSide(for: .left, free: [.bottom]), .bottom)
        XCTAssertNil(parkSide(for: .left, free: [.top]))
    }

    func testASideAcrossAGapIsNotTakenWhenTheWindowWouldShowBeyondIt() {
        // A display 300 points to the left, a third one above bridging the gap, one against the
        // right side: the left side is free, and a window 400 wide parked through it would lie
        // over the display beyond the gap.
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let beyond = CGRect(x: -1300, y: 0, width: 1000, height: 800)
        let bridge = CGRect(x: -1300, y: -600, width: 2300, height: 600)
        let beside = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let others = [beyond, bridge, beside]
        let slot = CGRect(x: 0, y: 0, width: 400, height: 700)
        let free = freeSides(of: display, others: others)
        XCTAssertEqual(free, [.left, .bottom])
        XCTAssertNil(hiddenParkedFrame(slot, display: display, others: others, edge: .left, strip: 1))
        XCTAssertEqual(parkSide(for: .left, free: free), .left)
        XCTAssertEqual(parkSide(for: .left, free: free, frame: slot, display: display, others: others, strip: 1), .bottom)
        // A window narrower than the gap fits in it: the side is taken.
        let narrow = CGRect(x: 0, y: 0, width: 250, height: 700)
        XCTAssertEqual(parkSide(for: .left, free: free, frame: narrow, display: display, others: others, strip: 1), .left)
    }

    func testParkedFrameLeavesTheStrip() {
        let w = CGRect(x: 4880, y: -581, width: 1244, height: 933)
        XCTAssertEqual(parkedFrame(w, display: rightDell, side: .bottom, strip: 8), CGRect(x: 4880, y: 1293, width: 1244, height: 933))
        XCTAssertEqual(parkedFrame(w, display: rightDell, side: .right, strip: 8), CGRect(x: 8224, y: -581, width: 1244, height: 933))
    }

    func testParkedThroughTheLeftOrTheTopTheStripIsTheWindowsFarEdge() {
        let w = CGRect(x: 4880, y: -581, width: 1244, height: 933)
        XCTAssertEqual(parkedFrame(w, display: rightDell, side: .left, strip: 8), CGRect(x: 4872 - 1244 + 8, y: -581, width: 1244, height: 933))
        XCTAssertEqual(parkedFrame(w, display: rightDell, side: .top, strip: 8), CGRect(x: 4880, y: -589 - 933 + 8, width: 1244, height: 933))
    }

    func testAWindowDoesNotHangPastTheBottomOntoADisplayBelow() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let slot = CGRect(x: 0, y: 0, width: 400, height: 700)
        // Against the top of the left side, and the whole of the right side.
        let beside = CGRect(x: -1000, y: 0, width: 1000, height: 300)
        let other = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        // Nothing below: the window goes under the display on the left, past the bottom.
        XCTAssertEqual(hiddenParkedFrame(slot, display: display, others: [beside, other], edge: .left, strip: 1),
                       CGRect(x: -399, y: 300, width: 400, height: 700))
        // A display below is where it would show: no side hides it.
        let below = CGRect(x: -1000, y: 800, width: 3000, height: 600)
        XCTAssertNil(hiddenParkedFrame(slot, display: display, others: [beside, other, below], edge: .left, strip: 1))
    }

    func testCompactParkedFrameSitsInTheDrawerCorner() {
        let w = CGRect(x: 4880, y: -581, width: 1244, height: 933)
        XCTAssertEqual(compactParkedFrame(w, display: rightDell, side: .bottom, strip: 8, edge: .left, width: 160, gap: 8),
                       CGRect(x: 4880, y: 1293, width: 160, height: 933))
        XCTAssertEqual(compactParkedFrame(w, display: rightDell, side: .bottom, strip: 8, edge: .right, width: 160, gap: 8),
                       CGRect(x: 8064, y: 1293, width: 160, height: 933))
    }

    // The owner's desk on 2026-11-10 (AX coordinates): the laptop lower than the monitors beside it.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let middle = CGRect(x: 1512, y: -589, width: 3360, height: 1890)
    private let above = CGRect(x: 1950, y: -1309, width: 2560, height: 720)
    private let right = CGRect(x: 4872, y: -589, width: 3360, height: 1890)

    func testAWindowHidesUnderTheDisplayThatIsAgainstPartOfTheSide() {
        let slot = CGRect(x: 1520, y: -556, width: 1100, height: 1849)
        let parked = hiddenParkedFrame(slot, display: middle, others: [laptop, above, right], edge: .left, strip: 1)
        // Through the left side, just under the laptop: one point of it is left on the monitor.
        XCTAssertEqual(parked, CGRect(x: 1512 - 1100 + 1, y: 982, width: 1100, height: 1849))
    }

    func testARightDrawerHidesThroughTheOtherSideWhenItsOwnIsTaken() {
        let slot = CGRect(x: 3764, y: -556, width: 1100, height: 1849)
        let parked = hiddenParkedFrame(slot, display: middle, others: [laptop, above, right], edge: .right, strip: 1)
        XCTAssertEqual(parked, CGRect(x: 1512 - 1100 + 1, y: 982, width: 1100, height: 1849))
    }

    func testAFreeSideHidesTheWindowWhereItIs() {
        let slot = CGRect(x: 7124, y: -556, width: 1100, height: 1849)
        let parked = hiddenParkedFrame(slot, display: right, others: [laptop, above, middle], edge: .right, strip: 1)
        XCTAssertEqual(parked, CGRect(x: 8232 - 1, y: -556, width: 1100, height: 1849))
    }

    func testNoSideHidesAWindowBetweenTwoDisplaysOfTheSameHeight() {
        let left = CGRect(x: -1848, y: -589, width: 3360, height: 1890)
        let slot = CGRect(x: 1520, y: -556, width: 1100, height: 1849)
        XCTAssertNil(hiddenParkedFrame(slot, display: middle, others: [left, right], edge: .left, strip: 1))
    }

    func testTheTopDrawerIsAsWideAsTheDisplay() {
        let d = DrawerSpec(edge: .top, size: 0.5,
                           layout: DrawerLayout(slots: [DrawerSlot(id: "main", rect: UnitRect(x: 0, y: 0, w: 1, h: 1))]))
        // A laptop alone, under its menu bar.
        let visible = CGRect(x: 0, y: 38, width: 1512, height: 944)
        XCTAssertEqual(drawerZone(d, visible: visible), CGRect(x: 0, y: 38, width: 1512, height: 472))
        XCTAssertEqual(drawerFrames([d], visible: visible, gap: 8)["top.main"], CGRect(x: 8, y: 46, width: 1496, height: 456))
        XCTAssertEqual(drawerUnitZone(d), UnitRect(x: 0, y: 0, w: 1, h: 0.5))
        XCTAssertEqual(drawerUnitZone(DrawerSpec(edge: .right, size: 0.25, layout: halves)), UnitRect(x: 0.75, y: 0, w: 0.25, h: 1))
        XCTAssertEqual(drawer(ofSlotKey: "top.main", in: [d])?.edge, .top)
    }

    func testTheTopDrawerIsParkedThroughASide() {
        // macOS refuses a window above the top of a display: the top drawer leaves by the left,
        // down to one point, like a left drawer.
        let slot = CGRect(x: 8, y: 46, width: 1496, height: 456)
        XCTAssertEqual(hiddenParkedFrame(slot, display: builtIn, others: [], edge: .top, strip: 1),
                       CGRect(x: -1495, y: 46, width: 1496, height: 456))
        XCTAssertEqual(parkSide(for: .top, free: [.right, .top, .bottom]), .right)
        XCTAssertEqual(parkSide(for: .top, free: [.top, .bottom]), .bottom)
        // Through the bottom, its tab is in the middle: the corners are the side drawers'.
        XCTAssertEqual(compactParkedFrame(slot, display: builtIn, side: .bottom, strip: 8, edge: .top, width: 160, gap: 8),
                       CGRect(x: 676, y: 974, width: 160, height: 456))
    }

    func testAWindowKeepsItsHeightInADrawerThatFitsItsContent() {
        let visible = CGRect(x: 0, y: 38, width: 1512, height: 944)
        let slot = CGRect(x: 8, y: 46, width: 1496, height: 456)
        // The slot's place and width, the window's own height.
        XCTAssertEqual(fittedFrame(slot: slot, windowHeight: 300, visible: visible, gap: 8), CGRect(x: 8, y: 46, width: 1496, height: 300))
        // Never past the bottom of the display.
        XCTAssertEqual(fittedFrame(slot: slot, windowHeight: 2000, visible: visible, gap: 8), CGRect(x: 8, y: 46, width: 1496, height: 928))
        // A window that does not say how high it is takes the slot.
        XCTAssertEqual(fittedFrame(slot: slot, windowHeight: nil, visible: visible, gap: 8), slot)
    }

    func testOnlyTheTopDrawerKeepsWindowHeights() throws {
        let layout = DrawerLayout(slots: [DrawerSlot(id: "main", rect: UnitRect(x: 0, y: 0, w: 1, h: 1))])
        XCTAssertTrue(DrawerSpec(edge: .top, size: 0.5, layout: layout, fitsContent: true).keepsWindowHeights)
        XCTAssertFalse(DrawerSpec(edge: .left, size: 0.5, layout: layout, fitsContent: true).keepsWindowHeights)
        XCTAssertFalse(DrawerSpec(edge: .top, size: 0.5, layout: layout).keepsWindowHeights)
        // Written only when on; a file without it reads as off.
        let plain = try JSONEncoder().encode(DrawerSpec(edge: .top, size: 0.5, layout: layout))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("fitsContent"))
        let read = try JSONDecoder().decode(DrawerSpec.self, from: plain)
        XCTAssertFalse(read.fitsContent)
        let fitting = try JSONEncoder().encode(DrawerSpec(edge: .top, size: 0.5, layout: layout, fitsContent: true))
        let back = try JSONDecoder().decode(DrawerSpec.self, from: fitting)
        XCTAssertTrue(back.fitsContent)
    }

    func testEachEdgeNamesItsCommands() {
        XCTAssertEqual(DrawerEdge.allCases.map(\.toggleCommand), ["drawerLeft", "drawerRight", "drawerTop"])
        XCTAssertEqual(DrawerEdge.top.sendCommand, "drawerSendTop")
        XCTAssertEqual(DrawerEdge.left.title, "Left")
    }
}
