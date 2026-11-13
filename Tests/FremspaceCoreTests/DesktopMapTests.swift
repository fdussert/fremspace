import XCTest
@testable import FremspaceCore

final class DesktopMapTests: XCTestCase {
    private let left = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "DELL")
    private let configurationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testFirstRunLinksByPosition() {
        let r = resolveDesktops(configured: 3, links: [nil, nil, nil], live: ["", "U2", "U3"])
        XCTAssertEqual(r.real, [0, 1, 2])
        XCTAssertEqual(r.links, [nil, "U2", "U3"])
    }

    func testRearrangedDesktopsFollowTheirUuid() {
        let r = resolveDesktops(configured: 3, links: [nil, "U2", "U3"], live: ["", "U3", "U2"])
        XCTAssertEqual(r.real, [0, 2, 1])
        XCTAssertEqual(r.links, [nil, "U2", "U3"])
    }

    func testTheDesktopWithoutUuidIsFollowedWhenAnotherTakesItsPosition() {
        // The first desktop of the main display (no uuid) dragged after the second in Mission
        // Control: its layout goes with it instead of applying nowhere.
        let moved = resolveDesktops(configured: 2, links: [nil, "U2"], live: ["U2", ""])
        XCTAssertEqual(moved.real, [1, 0])
        XCTAssertEqual(moved.links, [nil, "U2"])
        // A configured desktop that macOS does not have yet takes nobody's place.
        let short = resolveDesktops(configured: 3, links: [nil, "U2", nil], live: ["U2", ""])
        XCTAssertEqual(short.real, [1, 0, nil])
        // And a desktop with a uuid that is gone is still not replaced by the one without.
        let gone = resolveDesktops(configured: 2, links: ["U1", "U2"], live: ["", "U2"])
        XCTAssertEqual(gone.real, [nil, 1])
    }

    func testRemovedDesktopIsNotReplacedByItsNeighbour() {
        let r = resolveDesktops(configured: 3, links: [nil, "U2", "U3"], live: ["", "U3"])
        XCTAssertEqual(r.real, [0, nil, 1])
        XCTAssertEqual(r.links, [nil, "U2", "U3"])
    }

    func testAddedDesktopInTheMiddleIsUnconfigured() {
        let configuration = Configuration(id: configurationID, name: "Home", displays: [
            DisplaySpec(identity: left, spaces: [SpaceSpec(label: "Code"), SpaceSpec(label: "Web"), SpaceSpec(label: "Le reste")]),
        ])
        var links = DesktopLinks()
        links.links[DesktopLinks.key(configuration: configurationID, display: left)] = [nil, "U2", "U3"]
        let map = DesktopMap(configuration: configuration, live: [left: ["", "UX", "U2", "U3"]], links: &links)
        XCTAssertEqual(map.real(left, configured: 0), 0)
        XCTAssertEqual(map.real(left, configured: 1), 2)
        XCTAssertEqual(map.real(left, configured: 2), 3)
        XCTAssertNil(map.configured(left, real: 1))
        XCTAssertEqual(map.configured(left, real: 3), 2)
    }

    func testLinkMovesAUuid() {
        var links = DesktopLinks()
        let key = DesktopLinks.key(configuration: configurationID, display: left)
        links.links[key] = [nil, "U2", "U3"]
        links.link(configuration: configurationID, display: left, configured: 2, to: "U2")
        XCTAssertEqual(links.links[key], [nil, nil, "U2"])
    }

    func testRemovingAConfiguredDesktopDropsItsLink() {
        // I6: desktop 2 of 3 removed in the editor: desktop 3 keeps its own uuid.
        var links = DesktopLinks()
        let key = DesktopLinks.key(configuration: configurationID, display: left)
        links.links[key] = [nil, "U2", "U3"]
        links.removeDesktop(configuration: configurationID, display: left, index: 1)
        XCTAssertEqual(links.links[key], [nil, "U3"])
    }

    func testADesktopTakenOutOfTheConfigurationIsUnlisted() {
        // "Test", the last of four, removed in the editor: its link went, its macOS desktop stays.
        let configuration = Configuration(id: configurationID, name: "Home", displays: [
            DisplaySpec(identity: left, spaces: [SpaceSpec(label: "Code"), SpaceSpec(label: "Web"), SpaceSpec(label: "Le reste")]),
        ])
        var links = DesktopLinks()
        let key = DesktopLinks.key(configuration: configurationID, display: left)
        links.links[key] = [nil, "U2", "U3", "U4"]
        links.removeDesktop(configuration: configurationID, display: left, index: 3)
        let last = DesktopMap(configuration: configuration, live: [left: ["", "U2", "U3", "U4"]], links: &links)
        XCTAssertEqual(last.unconfigured(left, live: 4), [3])
        // One removed in the middle: the desktops after it keep theirs.
        links.links[key] = [nil, "U2", "U3", "U4"]
        links.removeDesktop(configuration: configurationID, display: left, index: 1)
        let middle = DesktopMap(configuration: configuration, live: [left: ["", "U2", "U3", "U4"]], links: &links)
        XCTAssertEqual(middle.unconfigured(left, live: 4), [1])
        // Nothing spare, and a display the configuration does not have.
        XCTAssertEqual(last.unconfigured(left, live: 3), [])
        let other = DisplayIdentity(vendor: 3, model: 3, serial: 3, name: "Other")
        XCTAssertEqual(last.unconfigured(other, live: 4), [])
    }

    func testNoDesktopIsUnlistedWhileAConfiguredOneIsLookedFor() {
        // "Web" lost its macOS desktop and another one sits there: it may be the one to take, so
        // it is not offered for removal.
        let configuration = Configuration(id: configurationID, name: "Home", displays: [
            DisplaySpec(identity: left, spaces: [SpaceSpec(label: "Code"), SpaceSpec(label: "Web")]),
        ])
        var links = DesktopLinks()
        links.links[DesktopLinks.key(configuration: configurationID, display: left)] = [nil, "U2"]
        let map = DesktopMap(configuration: configuration, live: [left: ["", "UX"]], links: &links)
        XCTAssertNil(map.real(left, configured: 1))
        XCTAssertEqual(map.unconfigured(left, live: 2), [])
    }

    func testTheNumberOfADesktopInMissionControl() {
        XCTAssertEqual(desktopNumber(inTitle: "Desktop 4"), 4)
        XCTAssertEqual(desktopNumber(inTitle: "Bureau 12"), 12)
        XCTAssertEqual(desktopNumber(inTitle: "2 Schreibtisch 7 "), 7)
        // A full-screen Space is named after its app, and has none.
        XCTAssertNil(desktopNumber(inTitle: "Notes"))
        XCTAssertNil(desktopNumber(inTitle: ""))
    }

    func testANewDesktopTakesTheSpareOneLeftInTheMiddle() {
        // "Web" was removed from the middle of the configuration (its macOS desktop U2 stayed),
        // then "Notes" was added at the end: it takes U2 instead of applying nowhere.
        let r = resolveDesktops(configured: 3, links: [nil, "U3", nil], live: ["", "U2", "U3"])
        XCTAssertEqual(r.real, [0, 2, 1])
        XCTAssertEqual(r.links, [nil, "U3", "U2"])
        // Two new desktops and one spare: the first takes it, the second waits for a desktop.
        let two = resolveDesktops(configured: 4, links: [nil, "U3", nil, nil], live: ["", "U2", "U3"])
        XCTAssertEqual(two.real, [0, 2, 1, nil])
        // With its own position free, a new desktop takes that one, as before.
        let end = resolveDesktops(configured: 4, links: [nil, "U3", nil, nil], live: ["", "U2", "U3", "U4"])
        XCTAssertEqual(end.real, [0, 2, 1, 3])
        XCTAssertEqual(end.links, [nil, "U3", "U2", "U4"])
    }

    func testTheDesktopWithoutUuidIsPreferredToASpareOne() {
        // The first desktop of the main display dragged to the end in Mission Control, with a
        // spare desktop before it: its layout follows it, and does not take the spare one.
        let r = resolveDesktops(configured: 2, links: [nil, "U2"], live: ["U2", "UX", ""])
        XCTAssertEqual(r.real, [2, 0])
        XCTAssertEqual(r.links, [nil, "U2"])
    }

    func testADesktopWhoseOwnIsGoneDoesNotTakeASpareOne() {
        // Linked to a desktop macOS no longer has: it is looked for, not replaced.
        let r = resolveDesktops(configured: 2, links: ["U1", "U2"], live: ["UX", "U2"])
        XCTAssertEqual(r.real, [nil, 1])
        XCTAssertEqual(r.links, ["U1", "U2"])
    }

    func testADesktopAddedOnASpareOneGoesWhereMissionControlShowsIt() {
        // "Web" was removed from the middle (U2 stayed on the Mac). The desktop added then takes U2
        // and its tab goes second, where Mission Control shows U2.
        let before = Configuration(id: configurationID, name: "Home", displays: [
            DisplaySpec(identity: left, spaces: [SpaceSpec(label: "Code"), SpaceSpec(label: "Le reste")]),
        ])
        var links = DesktopLinks()
        let key = DesktopLinks.key(configuration: configurationID, display: left)
        links.links[key] = [nil, "U3"]
        let live = [left: ["", "U2", "U3"]]
        let map = DesktopMap(configuration: before, live: live, links: &links)
        XCTAssertEqual(map.unconfigured(left, live: 3), [1])
        XCTAssertEqual(map.rank(left, real: 1), 1)
        XCTAssertNil(map.missionControlOrder(left))

        links.insertDesktop(configuration: configurationID, display: left, index: 1, uuid: "U2")
        XCTAssertEqual(links.links[key], [nil, "U2", "U3"])
        let after = Configuration(id: configurationID, name: "Home", displays: [
            DisplaySpec(identity: left, spaces: [SpaceSpec(label: "Code"), SpaceSpec(label: "Notes"), SpaceSpec(label: "Le reste")]),
        ])
        let added = DesktopMap(configuration: after, live: live, links: &links)
        XCTAssertEqual(added.real(left, configured: 1), 1)
        XCTAssertEqual(added.real(left, configured: 2), 2)
        XCTAssertNil(added.missionControlOrder(left))
        // A display that had no link yet gets a list long enough.
        var none = DesktopLinks()
        none.insertDesktop(configuration: configurationID, display: left, index: 2, uuid: "U3")
        XCTAssertEqual(none.links[key], [nil, nil, "U3"])
    }

    func testTheOrderOfMissionControlIsSaidWhenItIsNotTheTabs() {
        // The fourth configured desktop sits on the second desktop of the Mac.
        let configuration = Configuration(id: configurationID, name: "Home", displays: [
            DisplaySpec(identity: left, spaces: [SpaceSpec(label: "Music"), SpaceSpec(label: "Mail"), SpaceSpec(label: "Teams"), SpaceSpec(label: "Chat")]),
        ])
        var links = DesktopLinks()
        links.links[DesktopLinks.key(configuration: configurationID, display: left)] = [nil, "U3", "U4", "U2"]
        let map = DesktopMap(configuration: configuration, live: [left: ["", "U2", "U3", "U4"]], links: &links)
        XCTAssertEqual(map.missionControlOrder(left), [0, 3, 1, 2])
        // Not while a desktop is looked for: the order of the others says nothing yet.
        var gone = DesktopLinks()
        gone.links[DesktopLinks.key(configuration: configurationID, display: left)] = [nil, "U3", "U9", "U2"]
        let short = DesktopMap(configuration: configuration, live: [left: ["", "U2", "U3", "U4"]], links: &gone)
        XCTAssertNil(short.missionControlOrder(left))
    }
}
