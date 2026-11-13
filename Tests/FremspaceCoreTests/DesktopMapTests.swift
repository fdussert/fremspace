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
}
