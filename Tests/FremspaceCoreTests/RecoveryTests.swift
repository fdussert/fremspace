import CoreGraphics
import XCTest
@testable import FremspaceCore

final class RecoveryTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 33, width: 1512, height: 949)
    private let dell = CGRect(x: 1512, y: -559, width: 3360, height: 1860)

    func testMostlyVisibleWindowIsLeft() {
        // 60 % on the built-in display.
        XCTAssertNil(onScreenFrame(CGRect(x: -400, y: 100, width: 1000, height: 600), displays: [builtIn, dell]))
    }

    func testParkedWindowComesBackInside() {
        // The spike's Finder that arrived from another display at x = -880.
        let frame = onScreenFrame(CGRect(x: -880, y: 100, width: 1000, height: 600), displays: [builtIn, dell])
        XCTAssertEqual(frame, CGRect(x: 0, y: 100, width: 1000, height: 600))
    }

    func testHugeWindowIsClamped() {
        let frame = onScreenFrame(CGRect(x: 9000, y: 5000, width: 4000, height: 3000), displays: [builtIn, dell])
        XCTAssertEqual(frame, builtIn)
    }
}
