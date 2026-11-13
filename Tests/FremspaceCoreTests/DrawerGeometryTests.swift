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

    func testParkedFrameLeavesTheStrip() {
        let w = CGRect(x: 4880, y: -581, width: 1244, height: 933)
        XCTAssertEqual(parkedFrame(w, display: rightDell, side: .bottom, strip: 8), CGRect(x: 4880, y: 1293, width: 1244, height: 933))
        XCTAssertEqual(parkedFrame(w, display: rightDell, side: .right, strip: 8), CGRect(x: 8224, y: -581, width: 1244, height: 933))
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
}
