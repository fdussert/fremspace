import XCTest
@testable import FremspaceCore

final class EnforceTests: XCTestCase {
    private let left = DisplayIdentity(vendor: 4268, model: 53511, serial: 1, name: "Left")
    private var code: SpaceKey { SpaceKey(display: left, spaceIndex: 0) }
    private var web: SpaceKey { SpaceKey(display: left, spaceIndex: 1) }

    func testEnforcesOnlyWhileRunning() {
        XCTAssertTrue(mayEnforce(running: true, windowSpace: code, placedSpace: code))
        // Free (no configuration, config error, Spaces unreadable) or paused: no window is moved.
        XCTAssertFalse(mayEnforce(running: false, windowSpace: code, placedSpace: code))
    }

    func testWindowThatLeftItsSpaceIsNotEnforced() {
        // Dragged to another desktop or display: the user wins.
        XCTAssertFalse(mayEnforce(running: true, windowSpace: web, placedSpace: code))
        // Native full screen, display unplugged, or on all desktops: no desktop to read.
        XCTAssertFalse(mayEnforce(running: true, windowSpace: nil, placedSpace: code))
    }

    func testOnlyADragChoosesAnotherSlotOrResizesTheLayout() {
        XCTAssertEqual(handChange(dragged: true, moved: true, resizeLayouts: true),
                       HandChange(mayDropIntoSlot: true, mayResizeLayout: true))
        // Resized by hand: not a drop; the layout follows only with the setting on.
        XCTAssertEqual(handChange(dragged: true, moved: false, resizeLayouts: true),
                       HandChange(mayDropIntoSlot: false, mayResizeLayout: true))
        XCTAssertEqual(handChange(dragged: true, moved: true, resizeLayouts: false),
                       HandChange(mayDropIntoSlot: true, mayResizeLayout: false))
        // The window changed its own frame, no button down (a terminal after a font change, an
        // app settling after it was placed): neither, whatever the setting.
        XCTAssertEqual(handChange(dragged: false, moved: true, resizeLayouts: true),
                       HandChange(mayDropIntoSlot: false, mayResizeLayout: false))
        XCTAssertEqual(handChange(dragged: false, moved: false, resizeLayouts: true),
                       HandChange(mayDropIntoSlot: false, mayResizeLayout: false))
    }

    func testARefusedMoveIsTriedAgainTwiceThenTheWindowIsLeft() {
        XCTAssertEqual(moveRetry(failures: 1), .again(after: 1))
        XCTAssertEqual(moveRetry(failures: 2), .again(after: 3))
        // An app that never lets its window be moved is not asked at every pass.
        XCTAssertEqual(moveRetry(failures: 3), .giveUp)
        XCTAssertEqual(moveRetry(failures: 9), .giveUp)
    }

    func testFitActionRetriesThenStopsFighting() {
        XCTAssertEqual(fitAction(.fits, retriesLeft: 2), .keepLock)
        XCTAssertEqual(fitAction(.refuses, retriesLeft: 2), .unlock)
        XCTAssertEqual(fitAction(.resizeAgain, retriesLeft: 1), .resizeAgain)
        // Terminal-like apps resize by steps and never reach the slot size exactly: after the
        // retries, leave the window where it settled instead of fighting it on every pass.
        XCTAssertEqual(fitAction(.resizeAgain, retriesLeft: 0), .unlock)
    }
}
