import XCTest
@testable import FremspaceCore

final class TravelTests: XCTestCase {
    private let laptop = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let big = DisplayIdentity(vendor: 2, model: 1, serial: 1, name: "DELL (1)")
    private let side = DisplayIdentity(vendor: 3, model: 1, serial: 1, name: "XENEON")
    private let id = UUID()

    private func slot(_ id: String, _ app: String, _ rect: UnitRect = UnitRect(x: 0, y: 0, w: 1, h: 1)) -> Slot {
        Slot(id: id, rect: rect, rule: Rule(bundleID: app))
    }

    private var desk: Configuration {
        Configuration(id: UUID(), name: "Home desk", displays: [
            DisplaySpec(identity: laptop, spaces: [
                SpaceSpec(label: "Slack", layout: Layout(slots: [slot("main", "slack")]),
                          unmatched: .sendTo(display: big, spaceIndex: 2)),
            ], drawers: [DrawerSpec(edge: .left, size: 0.3, layout: DrawerLayout(slots: [
                DrawerSlot(id: "top", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rules: [Rule(bundleID: "notes")]),
            ]))]),
            DisplaySpec(identity: big, spaces: [
                SpaceSpec(label: "Code", layout: Layout(slots: [
                    slot("ide", "code", UnitRect(x: 0, y: 0, w: 0.6, h: 1)), slot("web", "brave", UnitRect(x: 0.6, y: 0, w: 0.4, h: 1)),
                ]), focusSlot: "ide"),
                SpaceSpec(label: "Chat", layout: Layout(slots: [slot("main", "slack")])),
                SpaceSpec(label: "The rest"),
                SpaceSpec(label: "Mail", layout: Layout(slots: [slot("main", "mail")])),
            ]),
            DisplaySpec(identity: side, ignored: true, spaces: [SpaceSpec(label: "Stats", layout: Layout(slots: [slot("main", "stats")]))]),
        ])
    }

    func testEverySlotOfTheOtherDisplaysBecomesADesktopOfTheKeptOne() throws {
        let travel = try XCTUnwrap(travelConfiguration(from: desk, keeping: laptop, id: id, name: "On the move"))
        XCTAssertEqual(travel.id, id)
        XCTAssertEqual(travel.name, "On the move")
        XCTAssertEqual(travel.displays.map(\.identity), [laptop])
        let spaces = travel.displays[0].spaces
        // Slack already has its desktop; the ignored display gives nothing.
        XCTAssertEqual(spaces.map(\.label), ["Slack", "Code · ide", "Code · web", "Mail", "Free"])
        XCTAssertEqual(spaces[1].layout?.slots.map(\.id), ["ide"])
        XCTAssertEqual(spaces[1].layout?.slots[0].rect, UnitRect(x: 0, y: 0, w: 1, h: 1))
        XCTAssertEqual(spaces[2].layout?.slots[0].rule.bundleID, "brave")
        XCTAssertNil(spaces[4].layout)
    }

    func testTheKeptDisplayKeepsItsDesktopsAndDrawersButSendsNothingAway() throws {
        let travel = try XCTUnwrap(travelConfiguration(from: desk, keeping: laptop, id: id, name: "On the move"))
        XCTAssertEqual(travel.displays[0].drawers, desk.displays[0].drawers)
        XCTAssertEqual(travel.displays[0].spaces[0].layout, desk.displays[0].spaces[0].layout)
        XCTAssertEqual(travel.displays[0].spaces[0].unmatched, .float)
    }

    func testAFreeDesktopIsNotAddedTwiceAndLabelsStayApart() throws {
        let travel = try XCTUnwrap(travelConfiguration(from: desk, keeping: big, id: id, name: "Big only"))
        // The big display has its free desktop; the laptop's Slack slot is already covered by "Chat".
        XCTAssertEqual(travel.displays[0].spaces.map(\.label), ["Code", "Chat", "The rest", "Mail"])
        var twice = desk
        twice.displays[1].spaces[3].label = "Slack"
        let labels = try XCTUnwrap(travelConfiguration(from: twice, keeping: laptop, id: id, name: "x")).displays[0].spaces.map(\.label)
        XCTAssertEqual(labels, ["Slack", "Code · ide", "Code · web", "Slack 2", "Free"])
    }

    func testAnIgnoredOrUnknownDisplayGivesNothing() {
        XCTAssertNil(travelConfiguration(from: desk, keeping: side, id: id, name: "x"))
        XCTAssertNil(travelConfiguration(from: desk, keeping: DisplayIdentity(vendor: 9, model: 9, serial: 9, name: "?"), id: id, name: "x"))
    }
}
