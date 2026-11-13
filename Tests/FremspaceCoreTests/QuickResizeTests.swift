import CoreGraphics
import XCTest
@testable import FremspaceCore

final class QuickResizeTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 33, width: 1512, height: 949)
    private let dell = CGRect(x: 1512, y: -559, width: 3360, height: 1860)
    private let window = CGRect(x: 100, y: 100, width: 600, height: 400)

    func testHalves() {
        XCTAssertEqual(quickFrame(.leftHalf, window: window, visible: builtIn), CGRect(x: 0, y: 33, width: 756, height: 949))
        XCTAssertEqual(quickFrame(.rightHalf, window: window, visible: builtIn), CGRect(x: 756, y: 33, width: 756, height: 949))
        XCTAssertEqual(quickFrame(.topHalf, window: window, visible: dell), CGRect(x: 1512, y: -559, width: 3360, height: 930))
        XCTAssertEqual(quickFrame(.bottomHalf, window: window, visible: dell), CGRect(x: 1512, y: 371, width: 3360, height: 930))
    }

    func testHalvesOfAnOddSizedDisplayStayInside() {
        let odd = CGRect(x: 0, y: 38, width: 1511, height: 1079)
        let left = quickFrame(.leftHalf, window: window, visible: odd), right = quickFrame(.rightHalf, window: window, visible: odd)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(right.maxX, odd.maxX)
        let top = quickFrame(.topHalf, window: window, visible: odd), bottom = quickFrame(.bottomHalf, window: window, visible: odd)
        XCTAssertEqual(top.maxY, bottom.minY)
        XCTAssertEqual(bottom.maxY, odd.maxY)
    }

    func testThirdsOfAWideDisplay() {
        XCTAssertEqual(quickFrame(.firstThird, window: window, visible: dell), CGRect(x: 1512, y: -559, width: 1120, height: 1860))
        XCTAssertEqual(quickFrame(.centerThird, window: window, visible: dell), CGRect(x: 2632, y: -559, width: 1120, height: 1860))
        XCTAssertEqual(quickFrame(.lastThird, window: window, visible: dell), CGRect(x: 3752, y: -559, width: 1120, height: 1860))
        XCTAssertEqual(quickFrame(.firstTwoThirds, window: window, visible: dell), CGRect(x: 1512, y: -559, width: 2240, height: 1860))
        XCTAssertEqual(quickFrame(.lastTwoThirds, window: window, visible: dell), CGRect(x: 2632, y: -559, width: 2240, height: 1860))
    }

    func testCenterKeepsSizeAndClamps() {
        XCTAssertEqual(quickFrame(.center, window: window, visible: builtIn), CGRect(x: 456, y: 308, width: 600, height: 400))
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        XCTAssertEqual(quickFrame(.center, window: huge, visible: builtIn), builtIn)
    }

    func testMaximize() {
        XCTAssertEqual(quickFrame(.maximize, window: window, visible: dell), dell)
    }
}
