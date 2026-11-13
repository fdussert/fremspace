import XCTest
@testable import FremspaceCore

final class StateStoreTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func testRoundTripAndMissingFile() throws {
        let store = StateStore(url: try temporaryURL())
        XCTAssertEqual(store.load(), FremspaceState())
        var state = FremspaceState()
        state.desktopLinks.links["k"] = [nil, "U2"]
        try store.save(state)
        XCTAssertEqual(store.load(), state)
    }

    func testFocusedSlotsAreKeptAndOlderStatesHaveNone() throws {
        let store = StateStore(url: try temporaryURL())
        let dell = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "DELL")
        var state = FremspaceState()
        state.focused = [FocusedSlot(configurationID: UUID(), desktop: ConfiguredDesktop(display: dell, index: 0), slotID: "ide")]
        try store.save(state)
        XCTAssertEqual(store.load().focused, state.focused)
        let older = try JSONDecoder().decode(FremspaceState.self, from: Data(#"{"desktopLinks":{"links":{}}}"#.utf8))
        XCTAssertTrue(older.focused.isEmpty)
    }

    func testCorruptFileLoadsEmptyAndIsKept() throws {
        let url = try temporaryURL()
        try Data("{ nope".utf8).write(to: url)
        let store = StateStore(url: url)
        XCTAssertEqual(store.load(), FremspaceState())
        let kept = url.deletingLastPathComponent().appendingPathComponent("state.json.corrupt")
        let keptData = try Data(contentsOf: kept)
        XCTAssertEqual(keptData, Data("{ nope".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOldStateWithoutRememberedLoads() throws {
        let url = try temporaryURL()
        try Data(#"{"desktopLinks":{"links":{"k":[null,"U2"]}}}"#.utf8).write(to: url)
        let state = StateStore(url: url).load()
        XCTAssertEqual(state.desktopLinks.links["k"], [nil, "U2"])
        XCTAssertEqual(state.remembered.entries, [])
    }

    func testDrawerMembersAreKeptAndOlderStatesHaveNone() throws {
        let display = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "DELL")
        var state = FremspaceState()
        state.drawerMembers = [SavedDrawerMember(window: SavedWindow(id: 42, pid: 7), bundleID: "com.apple.finder",
                                                 display: display, slot: "left.top")]
        state.takenOutOfDrawers = [SavedWindow(id: 43, pid: 8)]
        let decoded = try JSONDecoder().decode(FremspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let older = try JSONDecoder().decode(FremspaceState.self, from: Data("{}".utf8))
        XCTAssertEqual(older.drawerMembers, [])
        XCTAssertEqual(older.takenOutOfDrawers, [])
    }

    func testADrawerMemberIsFoundAgainOnlyInTheSameApp() {
        let display = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "DELL")
        let member = SavedDrawerMember(window: SavedWindow(id: 42, pid: 7), bundleID: "com.apple.finder",
                                       display: display, slot: "left.top")
        XCTAssertTrue(member.isAlive([42: 7]) { _ in "com.apple.finder" })
        // The same id and process number, in another app: the Mac restarted meanwhile.
        XCTAssertFalse(member.isAlive([42: 7]) { _ in "com.apple.Terminal" })
        XCTAssertFalse(member.isAlive([42: 7]) { _ in nil })
        XCTAssertFalse(member.isAlive([42: 9]) { _ in "com.apple.finder" })
    }

    func testWindowsSavedBeforeTheSessionAreForgotten() {
        let session = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(savedWindowsHold(savedAt: session.addingTimeInterval(60), idsSince: session))
        XCTAssertFalse(savedWindowsHold(savedAt: session.addingTimeInterval(-60), idsSince: session))
        XCTAssertTrue(savedWindowsHold(savedAt: nil, idsSince: session))

        let display = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "DELL")
        var state = FremspaceState()
        state.desktopLinks.links["k"] = [nil, "U2"]
        state.focused = [FocusedSlot(configurationID: UUID(), desktop: ConfiguredDesktop(display: display, index: 0), slotID: "ide")]
        state.paletteUses = ["app": 3]
        // What does not name a window by its id stays.
        let kept = state
        state.drawerMembers = [SavedDrawerMember(window: SavedWindow(id: 42, pid: 7), bundleID: "com.apple.finder",
                                                 display: display, slot: "left.top")]
        state.takenOutOfDrawers = [SavedWindow(id: 43, pid: 8)]
        state.splits = [SavedSplit(left: SavedWindow(id: 1, pid: 2), right: SavedWindow(id: 3, pid: 2), slotID: "web")]
        XCTAssertEqual(state.withoutSavedWindows(), kept)
    }

    func testTheStateFileSaysWhenItWasWritten() throws {
        let store = StateStore(url: try temporaryURL())
        XCTAssertNil(store.savedAt)
        try store.save(FremspaceState())
        let savedAt = try XCTUnwrap(store.savedAt)
        XCTAssertTrue(abs(savedAt.timeIntervalSinceNow) < 60)
    }

    func testASavedWindowIsAliveOnlyInTheSameProcess() {
        let window = SavedWindow(id: 42, pid: 7)
        XCTAssertTrue(window.isAlive([42: 7]))
        // The id was given to a window of another app, or the window is gone.
        XCTAssertFalse(window.isAlive([42: 9]))
        XCTAssertFalse(window.isAlive([:]))
    }
}
