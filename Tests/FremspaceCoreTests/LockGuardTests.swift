import CoreGraphics
import XCTest
@testable import FremspaceCore

final class LockGuardTests: XCTestCase {
    private let expected = CGRect(x: 8, y: 33, width: 2052, height: 1399)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func moved(by d: CGFloat) -> CGRect {
        expected.offsetBy(dx: d, dy: 0)
    }

    func testWithinToleranceDoesNothing() {
        var guard_ = LockGuard()
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 1), expected: expected, mouseDown: false, now: t0), .none)
    }

    func testRestoresWhenMovedOut() {
        var guard_ = LockGuard()
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0),
                       .restore(expected))
    }

    func testWaitsWhileMouseIsDown() {
        var guard_ = LockGuard()
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: true, now: t0), .none)
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false,
                                           now: t0.addingTimeInterval(0.5)),
                       .restore(expected))
    }

    func testGivesUpAfterThreeRestoresInFiveSeconds() {
        var guard_ = LockGuard()
        let actions = (0..<4).map {
            guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false,
                                now: t0.addingTimeInterval(Double($0)))
        }
        XCTAssertEqual(actions, [.restore(expected), .restore(expected), .restore(expected), .release])
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false,
                                           now: t0.addingTimeInterval(4)),
                       .none)
    }

    func testCounterResetsAfterWindow() {
        var guard_ = LockGuard()
        let actions = [0.0, 1, 2, 8].map {
            guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false,
                                now: t0.addingTimeInterval($0))
        }
        XCTAssertEqual(actions, Array(repeating: LockAction.restore(expected), count: 4))
    }

    func testForgetEndsRelease() {
        var guard_ = LockGuard(maxRestores: 0)
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0),
                       .release)
        guard_.forget(id: 1)
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0),
                       .release)
    }

    /// Re-apply (⌃⌥⌘R) gives every released window another chance: nothing stays released for good.
    func testEndReleasesGivesWindowsBack() {
        var guard_ = LockGuard(maxRestores: 0)
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0),
                       .release)
        guard_.endReleases()
        XCTAssertFalse(guard_.isReleased(1))
        XCTAssertEqual(guard_.frameChanged(id: 1, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0),
                       .release, "counts start again from zero, so with maxRestores 0 it releases again, freshly")
        guard_.endReleases()
        var lenient = LockGuard(maxRestores: 1)
        _ = lenient.frameChanged(id: 2, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0)
        XCTAssertEqual(lenient.frameChanged(id: 2, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0),
                       .release)
        lenient.endReleases()
        XCTAssertEqual(lenient.frameChanged(id: 2, actual: moved(by: 40), expected: expected, mouseDown: false, now: t0),
                       .restore(expected))
    }

    func testReleasedWindowIsLeftAloneUntilEndReleases() {
        // A window quick-resized out of its locked slot floats until ⌃⌥⌘R.
        var guard_ = LockGuard()
        let slot = CGRect(x: 0, y: 0, width: 500, height: 500)
        guard_.release(7)
        XCTAssertTrue(guard_.isReleased(7))
        XCTAssertEqual(guard_.frameChanged(id: 7, actual: CGRect(x: 0, y: 0, width: 756, height: 949), expected: slot,
                                           mouseDown: false, now: Date()), LockAction.none)
        guard_.endReleases()
        XCTAssertFalse(guard_.isReleased(7))
        XCTAssertEqual(guard_.frameChanged(id: 7, actual: CGRect(x: 0, y: 0, width: 756, height: 949), expected: slot,
                                           mouseDown: false, now: Date()), .restore(slot))
    }
}
