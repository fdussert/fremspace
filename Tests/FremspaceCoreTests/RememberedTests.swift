import CoreGraphics
import XCTest
@testable import FremspaceCore

final class RememberedTests: XCTestCase {
    private let dell = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "DELL")
    private let home = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let train = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func identity(_ tabs: [String]) -> WindowIdentity {
        WindowIdentity(bundleID: "com.brave.Browser", profile: "Work", document: nil, title: "t", tabs: tabs,
                       size: CGSize(width: 800, height: 600))
    }

    private func entry(_ id: UInt32, _ tabs: [String], desktop: Int, slot: String? = nil, configuration: UUID? = nil,
                       seen: TimeInterval = 1000) -> RememberedPlacement {
        RememberedPlacement(identity: identity(tabs), windowID: id, configurationID: configuration ?? home,
                            desktop: ConfiguredDesktop(display: dell, index: desktop), slotID: slot,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600), lastSeen: Date(timeIntervalSince1970: seen))
    }

    func testRecordReplacesSameWindow() {
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira"], desktop: 0))
        remembered.record(entry(10, ["Jira"], desktop: 1))
        XCTAssertEqual(remembered.entries.count, 1)
        XCTAssertEqual(remembered.entry(forWindow: 10)?.desktop.index, 1)
    }

    func testLiveIdWinsOverIdentity() {
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira"], desktop: 0))
        remembered.record(entry(11, ["GitHub"], desktop: 1))
        // Window 10 now shows GitHub's tabs, but it is still window 10.
        let matched = remembered.match(live: [10: identity(["GitHub"])], configurationID: home)
        XCTAssertEqual(matched[10]?.desktop.index, 0)
    }

    func testIdentityMatchesAfterRelaunch() {
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira", "Mail"], desktop: 0, slot: "code"))
        remembered.record(entry(11, ["GitHub"], desktop: 1, slot: "web"))
        let matched = remembered.match(live: [50: identity(["GitHub"]), 51: identity(["Jira", "Mail"])],
                                       configurationID: home)
        XCTAssertEqual(matched[50]?.slotID, "web")
        XCTAssertEqual(matched[51]?.slotID, "code")
    }

    func testIdsFromBeforeBootAreNotTrusted() {
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira"], desktop: 0, seen: 1000))
        // After a reboot, window 10 is another window.
        let matched = remembered.match(live: [10: identity(["Weather"])], configurationID: home,
                                       idsSince: Date(timeIntervalSince1970: 2000))
        XCTAssertNil(matched[10])
    }

    func testOtherConfigurationIsIgnored() {
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira"], desktop: 0, configuration: train))
        XCTAssertEqual(remembered.match(live: [10: identity(["Jira"]), 60: identity(["Jira"])], configurationID: home), [:])
    }

    func testPruneDropsOldest() {
        var remembered = Remembered()
        for i in 0..<5 { remembered.record(entry(UInt32(i), ["T\(i)"], desktop: 0, seen: TimeInterval(1000 + i))) }
        remembered.prune(keep: 3)
        XCTAssertEqual(Set(remembered.entries.map(\.windowID)), [2, 3, 4])
    }

    func testAWindowNotSeenForMonthsSinceAnEarlierSessionIsForgotten() {
        let day: TimeInterval = 24 * 3600
        let now = Date(timeIntervalSince1970: 400 * day)
        let boot = Date(timeIntervalSince1970: 395 * day)
        var remembered = Remembered()
        remembered.record(entry(1, ["Closed long ago"], desktop: 0, seen: 200 * day))
        remembered.record(entry(2, ["Before the restart"], desktop: 0, seen: 390 * day))
        remembered.record(entry(3, ["Open now"], desktop: 0, seen: 399 * day))
        remembered.prune(now: now, idsSince: boot)
        XCTAssertEqual(remembered.entries.map(\.windowID), [2, 3])
        // A window of this session keeps its entry however long it was left alone: the Mac has
        // been up for a year, and the window has not changed since its first day.
        var long = Remembered()
        long.record(entry(4, ["Left alone"], desktop: 0, seen: 10 * day))
        long.prune(now: now, idsSince: Date(timeIntervalSince1970: 5 * day))
        XCTAssertEqual(long.entries.map(\.windowID), [4])
        // Without a session to compare with, nothing is forgotten for its age.
        var plain = Remembered()
        plain.record(entry(5, ["Old"], desktop: 0, seen: day))
        plain.prune(now: now)
        XCTAssertEqual(plain.entries.count, 1)
    }

    func testAdoptRekeysAnEntry() {
        var remembered = Remembered()
        let old = entry(10, ["Jira"], desktop: 1, slot: "code")
        remembered.record(old)
        remembered.adopt(old, as: 70)
        XCTAssertNil(remembered.entry(forWindow: 10))
        XCTAssertEqual(remembered.entry(forWindow: 70)?.slotID, "code")
        XCTAssertEqual(remembered.entries.count, 1)
    }

    func testUnrecognisedWindowOfARememberedAppIsNotRecorded() {
        // C1: at login a window placed where it appeared must not be recorded (and then matched by
        // id) before the router compared it with the remembered windows of its app.
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira"], desktop: 1, slot: "web"))
        XCTAssertFalse(remembered.mayRecord(bundleID: "com.brave.Browser", configurationID: home, recognised: false))
        XCTAssertTrue(remembered.mayRecord(bundleID: "com.brave.Browser", configurationID: home, recognised: true))
        XCTAssertTrue(remembered.mayRecord(bundleID: "com.apple.finder", configurationID: home, recognised: false))
        XCTAssertTrue(remembered.mayRecord(bundleID: "com.brave.Browser", configurationID: train, recognised: false))
    }

    func testIdReusedAfterBootKeepsTheOlderEntry() {
        // I1: window 10 was Jira before the reboot; today another window got id 10.
        let boot = Date(timeIntervalSince1970: 2000)
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira"], desktop: 1, slot: "web", seen: 1000))
        remembered.record(entry(10, ["Weather"], desktop: 0, seen: 3000), idsSince: boot)
        XCTAssertEqual(remembered.entries.count, 2)
        XCTAssertEqual(remembered.entry(forWindow: 10, idsSince: boot)?.identity.tabs, ["Weather"])
        let other = entry(10, ["Weather"], desktop: 0, seen: 3000)
        remembered.adopt(remembered.entries[0], as: 55, idsSince: boot)
        XCTAssertEqual(remembered.entry(forWindow: 55, idsSince: .distantPast)?.slotID, "web")
        XCTAssertTrue(remembered.entries.contains(other))
    }

    func testRecordKeepsTheEntryOfAnotherConfiguration() {
        // I3: undocking must not erase the window's place in the docked configuration.
        var remembered = Remembered()
        remembered.record(entry(10, ["Jira"], desktop: 1, slot: "web", configuration: home))
        remembered.record(entry(10, ["Jira"], desktop: 0, configuration: train))
        XCTAssertEqual(remembered.entries.count, 2)
        XCTAssertEqual(remembered.entry(forWindow: 10, configurationID: home)?.slotID, "web")
    }

    func testRemovingADesktopDropsItsEntriesAndShiftsTheNext() {
        // I6: desktop 2 of 3 removed in the editor.
        var remembered = Remembered()
        remembered.record(entry(1, ["A"], desktop: 0))
        remembered.record(entry(2, ["B"], desktop: 1))
        remembered.record(entry(3, ["C"], desktop: 2))
        remembered.record(entry(4, ["D"], desktop: 1, configuration: train))
        remembered.removeDesktop(configuration: home, display: dell, index: 1)
        XCTAssertNil(remembered.entry(forWindow: 2))
        XCTAssertEqual(remembered.entry(forWindow: 1)?.desktop.index, 0)
        XCTAssertEqual(remembered.entry(forWindow: 3)?.desktop.index, 1)
        XCTAssertEqual(remembered.entry(forWindow: 4)?.desktop.index, 1)
    }

    func testMovingADesktopTakesItsEntriesAlong() {
        var remembered = Remembered()
        remembered.record(entry(1, ["A"], desktop: 0))
        remembered.record(entry(2, ["B"], desktop: 1))
        remembered.record(entry(3, ["C"], desktop: 2))
        remembered.record(entry(4, ["D"], desktop: 2, configuration: train))
        remembered.moveDesktop(configuration: home, display: dell, from: 2, to: 0)
        XCTAssertEqual(remembered.entry(forWindow: 3)?.desktop.index, 0)
        XCTAssertEqual(remembered.entry(forWindow: 1)?.desktop.index, 1)
        XCTAssertEqual(remembered.entry(forWindow: 2)?.desktop.index, 2)
        XCTAssertEqual(remembered.entry(forWindow: 4)?.desktop.index, 2)
    }
}
