import XCTest
import CoreGraphics
@testable import FremspaceCore

final class PlacementOrderTests: XCTestCase {
    private let half = CGRect(x: 0, y: 0, width: 500, height: 500)
    private let full = CGRect(x: 0, y: 0, width: 1000, height: 500)

    func testShrinkingWindowsGoBackToFront() {
        // Front window last, so it keeps covering the windows stacked behind it while they shrink.
        let moves = [Move(id: 1, from: full, to: half), Move(id: 2, from: full, to: half), Move(id: 3, from: full, to: half)]
        XCTAssertEqual(placementOrder(moves, frontToBack: [1, 2, 3]), [3, 2, 1])
    }

    func testGrowingWindowsGoFrontToBack() {
        // Front window first, so the windows behind it grow out of sight.
        let moves = [Move(id: 3, from: half, to: full), Move(id: 1, from: half, to: full), Move(id: 2, from: half, to: full)]
        XCTAssertEqual(placementOrder(moves, frontToBack: [1, 2, 3]), [1, 2, 3])
    }

    func testGrowingBeforeShrinkingAndUnknownLast() {
        let moves = [Move(id: 1, from: full, to: half), Move(id: 9, from: half, to: full), Move(id: 2, from: half, to: full)]
        XCTAssertEqual(placementOrder(moves, frontToBack: [1, 2]), [2, 9, 1])
    }

    func testSmallerWindowDoesNotRefuseItsSlot() {
        // A window the user is shrinking is smaller than its slot: that is not a minimum size.
        XCTAssertFalse(refusesSlot(actual: CGRect(x: 0, y: 0, width: 744, height: 367), slot: CGRect(x: 0, y: 0, width: 744, height: 441), tolerance: 2))
    }

    func testLargerWindowRefusesItsSlot() {
        XCTAssertTrue(refusesSlot(actual: CGRect(x: 0, y: 0, width: 770, height: 650), slot: CGRect(x: 0, y: 0, width: 744, height: 441), tolerance: 2))
        XCTAssertFalse(refusesSlot(actual: CGRect(x: 0, y: 0, width: 745, height: 442), slot: CGRect(x: 0, y: 0, width: 744, height: 441), tolerance: 2))
    }

    func testFitVerdict() {
        let slot = CGRect(x: 0, y: 0, width: 744, height: 441)
        XCTAssertEqual(fitVerdict(actual: CGRect(x: 0, y: 0, width: 745, height: 440), slot: slot, tolerance: 2), .fits)
        XCTAssertEqual(fitVerdict(actual: CGRect(x: 0, y: 0, width: 770, height: 650), slot: slot, tolerance: 2), .refuses)
        // Teams shrunk by hand ignored the size of the restore: set it again.
        XCTAssertEqual(fitVerdict(actual: CGRect(x: 0, y: 0, width: 744, height: 300), slot: slot, tolerance: 2), .resizeAgain)
        XCTAssertEqual(fitVerdict(actual: CGRect(x: 9, y: 0, width: 744, height: 441), slot: slot, tolerance: 2), .resizeAgain)
    }

    func testOnlyAMoveCanDropIntoAnotherSlot() {
        let slot = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertTrue(isMove(actual: CGRect(x: 1200, y: 30, width: 1001, height: 999), slot: slot, tolerance: 2))
        // Resizing a window towards the middle slot is not a move into it.
        XCTAssertFalse(isMove(actual: CGRect(x: 0, y: 0, width: 1800, height: 1000), slot: slot, tolerance: 2))
    }
}
