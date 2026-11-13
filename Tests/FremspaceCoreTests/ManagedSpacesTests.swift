import XCTest
@testable import FremspaceCore

final class ManagedSpacesTests: XCTestCase {
    // Shape of CGSCopyManagedDisplaySpaces, as read in the Task 0 spike: type 0 = desktop,
    // type 4 = native full-screen Space.
    private let raw: [[String: Any]] = [
        ["Display Identifier": "LEFT",
         "Current Space": ["ManagedSpaceID": UInt64(44)],
         "Spaces": [["ManagedSpaceID": UInt64(20), "type": 0],
                    ["ManagedSpaceID": UInt64(44), "type": 4],
                    ["ManagedSpaceID": UInt64(93), "type": 0]]],
        ["Display Identifier": "RIGHT",
         "Current Space": ["ManagedSpaceID": UInt64(21)],
         "Spaces": [["ManagedSpaceID": UInt64(21), "type": 0]]],
    ]

    func testDesktopIndexSkipsFullScreenSpaces() {
        let spaces = ManagedSpaces(raw)
        XCTAssertEqual(spaces.desktop(ofSpace: 20)?.displayUUID, "LEFT")
        XCTAssertEqual(spaces.desktop(ofSpace: 20)?.index, 0)
        XCTAssertEqual(spaces.desktop(ofSpace: 93)?.index, 1)
        XCTAssertNil(spaces.desktop(ofSpace: 44))
        XCTAssertNil(spaces.desktop(ofSpace: 999))
    }

    func testCurrentDesktopPerDisplay() {
        // The left display shows a full-screen Space: it has no current desktop.
        XCTAssertEqual(ManagedSpaces(raw).currentDesktops(), ["RIGHT": 0])
    }

    func testGarbageReadsAsEmpty() {
        let spaces = ManagedSpaces([["Spaces": "nope"]])
        XCTAssertEqual(spaces.currentDesktops(), [:])
        XCTAssertNil(spaces.desktop(ofSpace: 1))
    }

    func testReadsDesktopUUIDs() {
        let spaces = ManagedSpaces([
            ["Display Identifier": "MAIN",
             "Current Space": ["ManagedSpaceID": UInt64(1)],
             "Spaces": [["ManagedSpaceID": UInt64(1), "type": 0, "uuid": ""],
                        ["ManagedSpaceID": UInt64(158), "type": 4, "uuid": "FS"],
                        ["ManagedSpaceID": UInt64(134), "type": 0, "uuid": "U134"],
                        ["ManagedSpaceID": UInt64(136), "type": 0]]],
        ])
        XCTAssertEqual(spaces.displays.first?.desktops, [1, 134, 136])
        XCTAssertEqual(spaces.displays.first?.desktopUUIDs, ["", "U134", ""])
    }
}
