import XCTest
@testable import FremspaceCore

final class LoginRestoreTests: XCTestCase {
    private let builtIn = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let xeneon = DisplayIdentity(vendor: 3, model: 3, serial: 3, name: "XENEON")
    private let left = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "DELL left")

    private func slot(_ id: String, _ app: String, launch: Bool = true) -> Slot {
        Slot(id: id, rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: app), launchAtLogin: launch)
    }

    private var configuration: Configuration {
        Configuration(id: UUID(), name: "Home", displays: [
            DisplaySpec(identity: builtIn, spaces: [
                SpaceSpec(label: "Slack", layout: Layout(slots: [slot("s", "slack")])),
                SpaceSpec(label: "Mail", layout: Layout(slots: [slot("m", "outlook"), slot("n", "notes", launch: false)])),
            ]),
            DisplaySpec(identity: xeneon, ignored: true, spaces: [
                SpaceSpec(label: "Edge", layout: Layout(slots: [slot("e", "stats")])),
            ]),
            DisplaySpec(identity: left, spaces: [
                SpaceSpec(label: "Code", layout: Layout(slots: [slot("b", "brave"), slot("v", "vscode")])),
                SpaceSpec(label: "Web", layout: Layout(slots: [slot("w", "brave")])),
                SpaceSpec(label: "Le reste"),
            ]),
        ])
    }

    func testLoginStartWithinThreeMinutes() {
        let session = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(isLoginStart(appStart: session.addingTimeInterval(40), sessionStart: session))
        XCTAssertTrue(isLoginStart(appStart: session.addingTimeInterval(179), sessionStart: session))
    }

    func testRelaunchLaterIsNotLogin() {
        let session = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(isLoginStart(appStart: session.addingTimeInterval(3600), sessionStart: session))
    }

    func testAppsToLaunchSkipsRunningIgnoredAndOptedOut() {
        XCTAssertEqual(appsToLaunch(configuration: configuration, running: ["outlook"]), ["slack", "brave", "vscode"])
    }

    func testBraveListedOnce() {
        XCTAssertEqual(appsToLaunch(configuration: configuration, running: []).filter { $0 == "brave" }.count, 1)
    }

    func testOverdueAfterThirtySeconds() {
        var tracker = LaunchTracker()
        let start = Date(timeIntervalSince1970: 1000)
        tracker.launched("slack", at: start)
        XCTAssertEqual(tracker.overdue(now: start.addingTimeInterval(29)), [])
        XCTAssertEqual(tracker.overdue(now: start.addingTimeInterval(31)), ["slack"])
    }

    func testWindowSeenIsNotOverdue() {
        var tracker = LaunchTracker()
        let start = Date(timeIntervalSince1970: 1000)
        tracker.launched("slack", at: start)
        tracker.sawWindow("slack")
        XCTAssertEqual(tracker.overdue(now: start.addingTimeInterval(60)), [])
    }
}
