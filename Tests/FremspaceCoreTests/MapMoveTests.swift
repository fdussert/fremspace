import XCTest
@testable import FremspaceCore

final class MapMoveTests: XCTestCase {
    // Three displays with 4, 2 and 1 desktops.
    private let rows = [4, 2, 1]

    private func at(_ row: Int, _ column: Int) -> MapPlace { MapPlace(row: row, column: column) }

    func testLeftAndRightStayInTheRowAndStopAtItsEnds() {
        XCTAssertEqual(mapMove(rows: rows, from: at(0, 1), dx: 1, dy: 0), .to(at(0, 2)))
        XCTAssertEqual(mapMove(rows: rows, from: at(0, 3), dx: 1, dy: 0), .to(at(0, 3)))
        XCTAssertEqual(mapMove(rows: rows, from: at(1, 0), dx: -1, dy: 0), .to(at(1, 0)))
        XCTAssertEqual(mapMove(rows: rows, from: at(1, 1), dx: -1, dy: 0), .to(at(1, 0)))
    }

    func testUpAndDownKeepThePositionOrTakeTheLastDesktopOfAShorterRow() {
        XCTAssertEqual(mapMove(rows: rows, from: at(0, 1), dx: 0, dy: 1), .to(at(1, 1)))
        XCTAssertEqual(mapMove(rows: rows, from: at(0, 3), dx: 0, dy: 1), .to(at(1, 1)))
        XCTAssertEqual(mapMove(rows: rows, from: at(1, 1), dx: 0, dy: 1), .to(at(2, 0)))
        XCTAssertEqual(mapMove(rows: rows, from: at(2, 0), dx: 0, dy: -1), .to(at(1, 0)))
    }

    func testUpFromTheFirstRowAndDownFromTheLastLeaveTheMap() {
        XCTAssertEqual(mapMove(rows: rows, from: at(0, 2), dx: 0, dy: -1), .above)
        XCTAssertEqual(mapMove(rows: rows, from: at(2, 0), dx: 0, dy: 1), .below)
        XCTAssertEqual(mapMove(rows: [3], from: at(0, 1), dx: 0, dy: 1), .below)
    }

    func testARowWithoutDesktopIsSteppedOver() {
        XCTAssertEqual(mapMove(rows: [2, 0, 3], from: at(0, 1), dx: 0, dy: 1), .to(at(2, 1)))
        XCTAssertEqual(mapMove(rows: [2, 0], from: at(0, 1), dx: 0, dy: 1), .below)
        XCTAssertEqual(mapMove(rows: [0, 2], from: at(1, 0), dx: 0, dy: -1), .above)
    }

    func testAPlaceThatIsNotOnTheMapDoesNotMove() {
        XCTAssertEqual(mapMove(rows: rows, from: at(5, 0), dx: 1, dy: 0), .to(at(5, 0)))
        XCTAssertEqual(mapMove(rows: [], from: at(0, 0), dx: 0, dy: 1), .to(at(0, 0)))
    }
}
