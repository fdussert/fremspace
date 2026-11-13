import XCTest
@testable import FremspaceCore

final class CallsTests: XCTestCase {
    private let teams = "com.microsoft.teams2"

    private func configuration(_ slot: Slot) -> Configuration {
        let display = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "Built-in")
        return Configuration(id: UUID(), name: "Desk", displays: [
            DisplaySpec(identity: display, spaces: [SpaceSpec(label: "Teams", layout: Layout(slots: [slot]))]),
        ])
    }

    private func slot(_ bundleID: String, fullScreenCalls: Bool) -> Slot {
        var slot = Slot(id: "a", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: bundleID))
        slot.fullScreenCalls = fullScreenCalls
        return slot
    }

    func testCallsGoFullScreenOnlyForTheAppsTurnedOn() {
        let on = Config(configurations: [], fullScreenCalls: [teams])
        XCTAssertTrue(wantsFullScreenCalls(bundleID: teams, in: on))
        XCTAssertFalse(wantsFullScreenCalls(bundleID: "us.zoom.xos", in: on))
        XCTAssertFalse(wantsFullScreenCalls(bundleID: teams, in: Config(configurations: [])))
    }

    func testAppsWithoutAKnownCallWindowNeverGoFullScreen() {
        XCTAssertNil(callWindowMarker(bundleID: "com.apple.mail"))
        XCTAssertFalse(wantsFullScreenCalls(bundleID: "com.apple.mail",
                                            in: Config(configurations: [], fullScreenCalls: ["com.apple.mail"])))
    }

    func testTheGeneralListRoundTripsAndTheSlotOptionOfOneDayMovesToIt() throws {
        let on = Config(configurations: [configuration(slot(teams, fullScreenCalls: false))], fullScreenCalls: [teams])
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(on))
        XCTAssertEqual(decoded, on)
        let off = try JSONEncoder().encode(Config(configurations: []))
        XCTAssertFalse(String(decoding: off, as: UTF8.self).contains("fullScreenCalls"))
        // A file of 2026-11-10: the option sits on the Teams slot.
        let plain = try JSONEncoder().encode(Config(configurations: [configuration(slot(teams, fullScreenCalls: false))]))
        let legacy = String(decoding: plain, as: UTF8.self).replacingOccurrences(of: "\"id\":\"a\"", with: "\"id\":\"a\",\"fullScreenCalls\":true")
        XCTAssertTrue(legacy.contains("fullScreenCalls"))
        let migrated = try JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
        XCTAssertEqual(migrated.fullScreenCalls, [teams])
        let written = try JSONEncoder().encode(migrated.configurations)
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("fullScreenCalls"))
    }

    func testATitleTellsAZoomMeetingFromZoomsOtherWindows() throws {
        let marker = try XCTUnwrap(callWindowMarker(bundleID: "us.zoom.xos"))
        XCTAssertEqual(isCallWindow(title: "Zoom Meeting", marker: marker), true)
        XCTAssertEqual(isCallWindow(title: "Réunion Zoom", marker: marker), true)
        XCTAssertEqual(isCallWindow(title: "Zoom Meeting 40-Minutes", marker: marker), true)
        XCTAssertEqual(isCallWindow(title: "Zoom Workplace", marker: marker), false)
        // Teams is told by a control in the window, not by its title.
        let teamsMarker = try XCTUnwrap(callWindowMarker(bundleID: teams))
        XCTAssertNil(isCallWindow(title: "Weekly sync", marker: teamsMarker))
    }
}
