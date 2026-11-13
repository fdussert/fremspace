import XCTest
@testable import FremspaceCore

final class ReorderTests: XCTestCase {
    // Tabs at 0–60, 64–164, 168–208, 212–292.
    private let widths: [CGFloat] = [60, 100, 40, 80]
    private let laptop = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in Retina Display")
    private let big = DisplayIdentity(vendor: 2, model: 1, serial: 1, name: "DELL S3221QSA (1)")

    func testATabThatHasNotMovedStaysWhereItIs() {
        let preview = reorderPreview(widths: widths, spacing: 4, dragged: 1, translation: 0)
        XCTAssertEqual(preview, ReorderPreview(target: 1, offset: 0, shifts: [0, 0, 0, 0], snap: 0))
        XCTAssertEqual(reorderPreview(widths: widths, spacing: 4, dragged: 1, translation: 20)?.target, 1)
    }

    func testANeighbourGivesWayWhenTheLeadingEdgeOfTheDraggedTabPassesItsMiddle() {
        // The right edge of the first tab (60) passes the middle of the second (114) at 54 of travel.
        XCTAssertEqual(reorderPreview(widths: widths, spacing: 4, dragged: 0, translation: 53)?.target, 0)
        let right = reorderPreview(widths: widths, spacing: 4, dragged: 0, translation: 55)
        XCTAssertEqual(right?.target, 1)
        XCTAssertEqual(right?.shifts, [0, -64, 0, 0])
        XCTAssertEqual(right?.snap, 104)

        // The left edge of the last tab (212) dragged past the middles of the third (188) and the second (114).
        XCTAssertEqual(reorderPreview(widths: widths, spacing: 4, dragged: 3, translation: -97)?.target, 2)
        let left = reorderPreview(widths: widths, spacing: 4, dragged: 3, translation: -100)
        XCTAssertEqual(left?.target, 1)
        XCTAssertEqual(left?.shifts, [0, 84, 84, 0])
        XCTAssertEqual(left?.snap, -148)
    }

    func testAWideTabKeptInsideTheRowStillReachesBothEnds() {
        let far = reorderPreview(widths: widths, spacing: 4, dragged: 1, translation: 900)
        XCTAssertEqual(far?.offset, 128)
        XCTAssertEqual(far?.target, 3)
        XCTAssertEqual(far?.snap, 128)
        let back = reorderPreview(widths: widths, spacing: 4, dragged: 1, translation: -900)
        XCTAssertEqual(back?.offset, -64)
        XCTAssertEqual(back?.target, 0)
        XCTAssertEqual(back?.snap, -64)
    }

    func testDroppedInItsNewPlaceTheTabIsStillThere() {
        for (dragged, translation) in [(0, CGFloat(55)), (3, CGFloat(-100)), (1, CGFloat(900)), (2, CGFloat(-60))] {
            guard let preview = reorderPreview(widths: widths, spacing: 4, dragged: dragged, translation: translation) else { return XCTFail("no preview") }
            XCTAssertEqual(reorderPreview(widths: widths, spacing: 4, dragged: dragged, translation: preview.snap)?.target, preview.target)
        }
    }

    func testATabThatIsNotInTheRowHasNoPreview() {
        XCTAssertNil(reorderPreview(widths: widths, spacing: 4, dragged: 4, translation: 10))
        XCTAssertNil(reorderPreview(widths: [], spacing: 4, dragged: 0, translation: 10))
    }

    func testADisplayIsCalledByTheOwnersNameWhenThereIsOne() {
        var display = DisplaySpec(identity: big, spaces: [SpaceSpec(label: "Code")])
        XCTAssertEqual(display.displayName, "DELL S3221QSA (1)")
        display.label = "Left"
        XCTAssertEqual(display.displayName, "Left")
        display.label = "   "
        XCTAssertEqual(display.displayName, "DELL S3221QSA (1)")

        let desk = Configuration(id: UUID(), name: "Desk", displays: [DisplaySpec(identity: big, spaces: [], label: "Left")])
        XCTAssertEqual(desk.displayName(big), "Left")
        XCTAssertEqual(desk.displayName(laptop), "Built-in Retina Display")
    }

    func testTheOwnersNameIsWrittenOnlyWhenThereIsOne() throws {
        var display = DisplaySpec(identity: big, spaces: [SpaceSpec(label: "Code")])
        let plain = String(decoding: try JSONEncoder().encode(display), as: UTF8.self)
        XCTAssertFalse(plain.contains("\"label\":\"\""))
        let same = try JSONDecoder().decode(DisplaySpec.self, from: Data(plain.utf8))
        XCTAssertEqual(same, display)
        display.label = "Left"
        let back = try JSONDecoder().decode(DisplaySpec.self, from: try JSONEncoder().encode(display))
        XCTAssertEqual(back.label, "Left")
        XCTAssertEqual(back, display)
    }

    func testAShortDisplayIsNamedAsTheOwnerCallsIt() {
        let id = UUID()
        var facts = AttentionFacts()
        facts.config = Config(configurations: [Configuration(id: id, name: "Desk", displays: [
            DisplaySpec(identity: big, spaces: [SpaceSpec(label: "Code"), SpaceSpec(label: "Rest")], label: "Left"),
        ])])
        facts.active = id
        facts.desktopCounts = [big: 1]
        XCTAssertEqual(attentionItems(facts).first?.title, "Left is 1 desktop short")
    }
}
