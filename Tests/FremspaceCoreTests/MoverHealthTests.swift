import XCTest
@testable import FremspaceCore

final class MoverHealthTests: XCTestCase {
    func testTwoFailedSendsInARowMakeItUnavailable() {
        var health = MoverHealth()
        XCTAssertTrue(health.isAvailable)
        health.record(success: false)
        XCTAssertTrue(health.isAvailable)
        health.record(success: false)
        XCTAssertFalse(health.isAvailable)
    }

    func testASuccessResetsTheCount() {
        var health = MoverHealth()
        health.record(success: false)
        health.record(success: true)
        health.record(success: false)
        XCTAssertTrue(health.isAvailable)
    }

    func testReapplyingTheLayoutsTriesAgain() {
        var health = MoverHealth()
        health.record(success: false)
        health.record(success: false)
        XCTAssertFalse(health.isAvailable)
        health.retry()
        XCTAssertTrue(health.isAvailable)
        // The count starts again too: one more failure is not enough to stop.
        health.record(success: false)
        XCTAssertTrue(health.isAvailable)
        health.record(success: false)
        XCTAssertFalse(health.isAvailable)
    }

    func testAnOperationThatIsNotOnThisMacOSIsNeverAvailable() {
        var health = MoverHealth(present: false)
        XCTAssertFalse(health.isAvailable)
        health.record(success: true)
        XCTAssertFalse(health.isAvailable)
        health.retry()
        XCTAssertFalse(health.isAvailable)
    }

    func testUnavailableStaysUntilASuccess() {
        var health = MoverHealth()
        health.record(success: false)
        health.record(success: false)
        health.record(success: false)
        XCTAssertFalse(health.isAvailable)
        health.record(success: true)
        XCTAssertTrue(health.isAvailable)
    }
}
