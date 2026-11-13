import XCTest
@testable import FremspaceCore

final class LayoutEditingTests: XCTestCase {
    private let code = Layout(slots: [
        Slot(id: "ide", rect: UnitRect(x: 0, y: 0, w: 0.6, h: 1), rule: Rule(bundleID: "com.microsoft.VSCode")),
        Slot(id: "web", rect: UnitRect(x: 0.6, y: 0, w: 0.4, h: 1), rule: Rule(bundleID: "com.brave.Browser")),
    ])

    func testSplitAndRemoveRoundTrip() {
        let split = FremspaceCore.split(code, slot: "web", along: .horizontal, newID: "notes", rule: Rule(bundleID: "com.sublimetext.4"))
        XCTAssertEqual(split.slots.first { $0.id == "web" }?.rect, UnitRect(x: 0.6, y: 0, w: 0.4, h: 0.5))
        XCTAssertEqual(split.slots.first { $0.id == "notes" }?.rect, UnitRect(x: 0.6, y: 0.5, w: 0.4, h: 0.5))
        XCTAssertNil(isValid(split))
        XCTAssertEqual(remove(split, slot: "notes"), code)
    }

    func testADividerStepsFromStopToStopAndStopsAtItsLimit() {
        // On a laptop the stops are 1/3, 2/5, 1/2, 3/5, 2/3.
        let divider = dividers(code)[0]
        let further = stepped(code, divider: divider, forward: true, length: 1512)
        XCTAssertEqual(further.slots.first { $0.id == "ide" }?.rect.w, 2.0 / 3)
        XCTAssertEqual(stepped(code, divider: divider, forward: false, length: 1512).slots.first { $0.id == "ide" }?.rect.w, 0.5)
        // The slot on the other side keeps the smallest stop: nothing beyond 2/3.
        XCTAssertEqual(stepped(further, divider: dividers(further)[0], forward: true, length: 1512), further)
    }

    func testASlotGrowsByTheDividerItHas() {
        // "ide" has the divider on its right; "web" reaches the right edge and moves the one on its left.
        XCTAssertEqual(stepped(code, slot: "ide", by: .vertical, grow: true, length: 1512).slots.first { $0.id == "ide" }?.rect.w, 2.0 / 3)
        let wider = stepped(code, slot: "web", by: .vertical, grow: true, length: 1512)
        XCTAssertEqual(wider.slots.first { $0.id == "web" }?.rect, UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))
        XCTAssertEqual(stepped(code, slot: "web", by: .vertical, grow: false, length: 1512).slots.first { $0.id == "web" }?.rect.x, 2.0 / 3)
        // As high as the display: no divider to move that way.
        XCTAssertEqual(stepped(code, slot: "ide", by: .horizontal, grow: true, length: 982), code)
    }

    func testDividersOfTheCodeLayout() {
        XCTAssertEqual(dividers(code), [Divider(axis: .vertical, position: 0.6, before: ["ide"], after: ["web"])])
    }

    func testMoveSnapsToEighthsOnLargeDisplays() {
        let moved = move(code, divider: dividers(code)[0], to: 0.37, length: 3360)
        XCTAssertEqual(moved.slots.map(\.rect), [UnitRect(x: 0, y: 0, w: 0.375, h: 1), UnitRect(x: 0.375, y: 0, w: 0.625, h: 1)])
    }

    func testDividerClampsAtTheSmallestStop() {
        let wide = move(code, divider: dividers(code)[0], to: 0.98, length: 3360)
        XCTAssertEqual(wide.slots.first { $0.id == "ide" }?.rect.w, 0.875)
        let narrow = move(code, divider: dividers(code)[0], to: 0.98, length: 1512)
        XCTAssertEqual(narrow.slots.first { $0.id == "ide" }?.rect.w, 2.0 / 3)
    }

    func testIsValidReportsOverlaps() {
        var bad = code
        bad.slots[1].rect = UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)
        XCTAssertNotNil(isValid(bad))
        var dup = code
        dup.slots[1].id = "ide"
        XCTAssertNotNil(isValid(dup))
        XCTAssertNil(isValid(code))
    }

    func testSplitRefusedWhenHalvesWouldBeBelowTheSmallestStop() {
        let halves = Layout(slots: [
            Slot(id: "a", rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: "x")),
            Slot(id: "b", rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: "y")),
        ])
        XCTAssertFalse(canSplit(halves, slot: "b", along: .vertical, length: 1512))
        XCTAssertTrue(canSplit(halves, slot: "b", along: .vertical, length: 3360))
        XCTAssertTrue(canSplit(halves, slot: "b", along: .horizontal, length: 982))
    }

    func testMoveNeverMakesSlotsOverlapAcrossRows() {
        // Top: A | B at 1/2. Bottom: C [0, 1/2], a gap, D [0.6, 1]. The 1/2 line is one divider.
        let layout = Layout(slots: [
            Slot(id: "A", rect: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5), rule: Rule(bundleID: "a")),
            Slot(id: "B", rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.5), rule: Rule(bundleID: "b")),
            Slot(id: "C", rect: UnitRect(x: 0, y: 0.5, w: 0.5, h: 0.5), rule: Rule(bundleID: "c")),
            Slot(id: "D", rect: UnitRect(x: 0.6, y: 0.5, w: 0.4, h: 0.5), rule: Rule(bundleID: "d")),
        ])
        guard let divider = dividers(layout).first(where: { $0.axis == .vertical }) else { return XCTFail("no divider") }
        let moved = move(layout, divider: divider, to: 2.0 / 3, length: 1512)
        XCTAssertNil(isValid(moved))
        XCTAssertEqual(moved.slots.first { $0.id == "C" }?.rect.w, 0.6)
    }

    // MARK: - Resized by hand, swapped

    private var desk: Layout {
        Layout(slots: [
            Slot(id: "ide", rect: UnitRect(x: 0, y: 0, w: 0.625, h: 1), rule: Rule(bundleID: "a")),
            Slot(id: "web", rect: UnitRect(x: 0.625, y: 0, w: 0.375, h: 0.5), rule: Rule(bundleID: "b")),
            Slot(id: "term", rect: UnitRect(x: 0.625, y: 0.5, w: 0.375, h: 0.5), rule: Rule(bundleID: "c")),
        ])
    }
    private let screen = CGRect(x: 1512, y: -589, width: 3360, height: 1890)

    private func rect(_ layout: Layout?, _ id: String) -> UnitRect? { layout?.slots.first { $0.id == id }?.rect }

    func testDraggingAnInnerEdgeMovesItsDividerAndTheSlotsBehindIt() {
        let frames = slotFrames(layout: desk, focus: nil, visible: screen, gap: 8)
        var dragged = frames["ide"]!
        // The right edge of the editor, pulled left to about half the screen.
        dragged.size.width = 3360 * 0.5 - 30
        let out = resized(desk, slot: "ide", from: frames["ide"]!, to: dragged, visible: screen)
        XCTAssertEqual(rect(out, "ide"), UnitRect(x: 0, y: 0, w: 0.5, h: 1))
        XCTAssertEqual(rect(out, "web"), UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.5))
        XCTAssertEqual(rect(out, "term"), UnitRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5))
    }

    func testTheEdgeBetweenTwoStackedSlotsMovesOnlyThem() {
        let frames = slotFrames(layout: desk, focus: nil, visible: screen, gap: 8)
        var dragged = frames["term"]!
        // The top of the lower slot, pulled up to a quarter of the height.
        dragged.origin.y = screen.minY + 1890 * 0.25 + 10
        dragged.size.height = frames["term"]!.maxY - dragged.origin.y
        let out = resized(desk, slot: "term", from: frames["term"]!, to: dragged, visible: screen)
        XCTAssertEqual(rect(out, "term"), UnitRect(x: 0.625, y: 0.25, w: 0.375, h: 0.75))
        XCTAssertEqual(rect(out, "web"), UnitRect(x: 0.625, y: 0, w: 0.375, h: 0.25))
        XCTAssertEqual(rect(out, "ide"), rect(desk, "ide"))
    }

    func testAMoveAnOuterEdgeOrATinyResizeChangeNothing() {
        let frames = slotFrames(layout: desk, focus: nil, visible: screen, gap: 8)
        let ide = frames["ide"]!
        XCTAssertNil(resized(desk, slot: "ide", from: ide, to: ide.offsetBy(dx: -400, dy: 60), visible: screen))
        var outer = ide
        outer.origin.x += 300
        outer.size.width -= 300
        XCTAssertNil(resized(desk, slot: "ide", from: ide, to: outer, visible: screen))
        var tiny = ide
        tiny.size.width -= 9
        XCTAssertNil(resized(desk, slot: "ide", from: ide, to: tiny, visible: screen))
        XCTAssertNil(resized(desk, slot: "gone", from: ide, to: outer, visible: screen))
    }

    func testSwappingExchangesThePlacesAndNothingElse() {
        let out = swapped(desk, "ide", "web")
        XCTAssertEqual(rect(out, "ide"), rect(desk, "web"))
        XCTAssertEqual(rect(out, "web"), rect(desk, "ide"))
        XCTAssertEqual(out.slots.map(\.id), ["ide", "web", "term"])
        XCTAssertEqual(out.slots.map(\.rule.bundleID), ["a", "b", "c"])
        XCTAssertEqual(swapped(desk, "ide", "nowhere"), desk)
    }

    func testTakingAnAppOutOfASlot() {
        var slot = Slot(id: "main", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: "com.example.chat"), locked: false)
        slot.rules.append(Rule(bundleID: "com.example.mail"))
        // The first of two: the other becomes the one the slot is named after.
        let one = removingApp(slot, at: 0)
        XCTAssertEqual(one.rules.map(\.bundleID), ["com.example.mail"])
        // The last one: the slot stays, empty, with its place and its switches.
        let none = removingApp(one, at: 0)
        XCTAssertEqual(none.rules.map(\.bundleID), [""])
        XCTAssertEqual(none.rect, slot.rect)
        XCTAssertFalse(none.locked)
        // A position it does not have changes nothing.
        XCTAssertEqual(removingApp(slot, at: 5), slot)
    }
}
