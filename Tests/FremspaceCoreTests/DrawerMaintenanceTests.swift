import XCTest
import CoreGraphics
@testable import FremspaceCore

final class DrawerMaintenanceTests: XCTestCase {
    private let right = DisplayIdentity(vendor: 4268, model: 53511, serial: 2, name: "Right")
    private let left = DisplayIdentity(vendor: 4268, model: 53511, serial: 1, name: "Left")
    private var browse: DisplayIdentity { right }
    private var code: DisplayIdentity { left }

    func testOnlyAClosedWindowIsGone() {
        XCTAssertTrue(memberIsGone(spaceIsShown: true, appHidden: false, inAppWindowList: false))
        // Hidden app (Cmd-H): its windows are off screen but alive.
        XCTAssertFalse(memberIsGone(spaceIsShown: true, appHidden: true, inAppWindowList: false))
        // Desktop not shown yet (Cmd-Tab to another desktop, switch in progress): cannot tell.
        XCTAssertFalse(memberIsGone(spaceIsShown: false, appHidden: false, inAppWindowList: false))
        XCTAssertFalse(memberIsGone(spaceIsShown: true, appHidden: false, inAppWindowList: true))
    }

    func testAnEmptyWindowListFromAnAppThatStillShowsWindowsIsNoAnswer() {
        // The usual case: the app lists its windows, the member (3) is among them or not.
        XCTAssertTrue(windowListAnswers(listed: [1, 2], onScreen: [3]))
        // Its last window, the member, closed or hidden instead of destroyed (Finder): nothing
        // listed, and the window server no longer shows the member.
        XCTAssertTrue(windowListAnswers(listed: [], onScreen: []))
        // Behind the lock screen, or just after it: nothing listed while the member is there.
        XCTAssertFalse(windowListAnswers(listed: [], onScreen: [3]))
    }

    func testMembersOfARemovedOrRenamedDrawerSlotAreStale() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(2, to: browse, slot: "left.bottom")
        s.send(3, to: code, slot: "left.top")
        let stale = staleMembers(s) { space in space == self.browse ? ["left.upper", "left.bottom"] : [] }
        XCTAssertEqual(Set(stale), [1, 3])
    }

    func testMembersFollowTheDesktopTheirDisplayShows() {
        var s = DrawerState()
        s.send(1, to: right, slot: "left.top")
        s.send(2, to: right, slot: "left.top")
        s.send(3, to: left, slot: "left.top")
        s.send(4, to: right, slot: "left.bottom")
        s.send(5, to: right, slot: "left.bottom")
        // Right shows its second desktop. 1 is still on the first, 2 already followed, 4 was taken to
        // the other display by macOS, 5 cannot be read. Left is on a full-screen Space.
        let places: [UInt32: SpaceKey] = [1: SpaceKey(display: right, spaceIndex: 0), 2: SpaceKey(display: right, spaceIndex: 1),
                                          3: SpaceKey(display: left, spaceIndex: 0), 4: SpaceKey(display: left, spaceIndex: 0)]
        let bring = membersToBring(s, shown: [right: 1]) { places[$0] }
        XCTAssertEqual(bring.map(\.id), [1])
        XCTAssertEqual(bring.first?.to, SpaceKey(display: right, spaceIndex: 1))
        // Left shows a desktop again: its member follows too.
        XCTAssertEqual(membersToBring(s, shown: [right: 1, left: 2]) { places[$0] }.map(\.id), [1, 3])
    }

    func testMembersOfADisconnectedDisplayAreKept() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(2, to: code, slot: "left.top")
        let plan = restorePlan(s, connected: [left])
        XCTAssertEqual(plan.restore, [2])
        XCTAssertEqual(plan.keep, [1])
    }

    func testAMemberThatCouldNotBeBroughtBackStaysInTheParkedFile() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(2, to: browse, slot: "left.top")
        s.send(3, to: code, slot: "right.top")
        XCTAssertEqual(parkedMembers(s, notBroughtBack: []), [1, 2, 3], "closed drawers: every member is parked")
        // Everything is brought back (a quit, a pause): the drawers count as open, and the window
        // of 2, whose app did not answer, is still where it was parked.
        s.setOpen(browse, true)
        s.setOpen(code, true)
        XCTAssertEqual(parkedMembers(s, notBroughtBack: []), [])
        XCTAssertEqual(parkedMembers(s, notBroughtBack: [2]), [2])
        // A window that is no longer a member is nobody's to bring back.
        s.remove(2)
        XCTAssertEqual(parkedMembers(s, notBroughtBack: [2]), [])
    }

    func testActivatingAStackedMemberBringsItToFront() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(2, to: browse, slot: "left.top")
        XCTAssertEqual(activate(1, on: browse, state: &s, isMainLayoutWindow: false), .open(browse, edge: "left"))
        XCTAssertEqual(s.stacks(browse)["left.top"], [1, 2])
    }

    /// The parked-windows file survives a crash: written, then read back by the next launch.
    func testParkedFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("parked.json")
        XCTAssertEqual(ParkedFile.load(url), [], "no file: nothing parked")
        let parked = [ParkedWindow(id: 7, pid: 42, bundleID: "com.apple.finder", frame: CGRect(x: 4880, y: -551, width: 1244, height: 918))]
        try ParkedFile.save(parked, to: url)
        XCTAssertEqual(ParkedFile.load(url), parked)
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(ParkedFile.load(url), [], "an unreadable file reads as nothing parked")
        try? FileManager.default.removeItem(at: dir)
    }

    /// After a crash, only windows still alive in the same process come back; an id now used by another
    /// process, or gone, is dropped.
    func testRecoveryRestoresOnlyLiveWindowsOfTheSameProcess() {
        let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        let saved = [ParkedWindow(id: 1, pid: 10, bundleID: "a", frame: frame),
                     ParkedWindow(id: 2, pid: 11, bundleID: "b", frame: frame),
                     ParkedWindow(id: 3, pid: 12, bundleID: "c", frame: frame)]
        let apps: [Int32: String] = [10: "a", 11: "b", 99: "b"]
        let plan = recoveryPlan(saved: saved, alive: [1: 10, 2: 99]) { apps[$0] }
        XCTAssertEqual(plan.restore.map(\.id), [1])
        XCTAssertEqual(plan.drop.sorted(), [2, 3])
    }

    /// After a restart of the Mac the same id and the same process number can be another app's.
    func testRecoveryLeavesAWindowThatIsNowAnotherApps() {
        let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        let saved = [ParkedWindow(id: 1, pid: 10, bundleID: "a", frame: frame),
                     ParkedWindow(id: 2, pid: 11, bundleID: "?", frame: frame)]
        let plan = recoveryPlan(saved: saved, alive: [1: 10, 2: 11]) { $0 == 10 ? "other" : nil }
        // The second was saved for a process without a bundle id, and still is one.
        XCTAssertEqual(plan.restore.map(\.id), [2])
        XCTAssertEqual(plan.drop, [1])
    }
}
