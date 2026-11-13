import XCTest
@testable import FremspaceCore

final class MenuGlyphTests: XCTestCase {
    private let layout = Layout(slots: [
        Slot(id: "ide", rect: UnitRect(x: 0, y: 0, w: 0.6, h: 1), rule: Rule(bundleID: "a")),
        Slot(id: "side", rect: UnitRect(x: 0.6, y: 0, w: 0.4, h: 1), rule: Rule(bundleID: "b")),
    ])

    func testTheGlyphDrawsTheLayoutAndTellsTheSlotInFront() {
        XCTAssertEqual(menuGlyph(running: true, paused: false, layout: layout, focusedSlot: nil, activeSlot: "side"),
                       .layout(slots: layout.slots.map(\.rect), active: 1))
        // A floating window has the keyboard: no slot is in front.
        XCTAssertEqual(menuGlyph(running: true, paused: false, layout: layout, focusedSlot: nil, activeSlot: nil),
                       .layout(slots: layout.slots.map(\.rect), active: nil))
    }

    func testASlotInFocusFillsTheGlyph() {
        let whole = [UnitRect(x: 0, y: 0, w: 1, h: 1)]
        XCTAssertEqual(menuGlyph(running: true, paused: false, layout: layout, focusedSlot: "ide", activeSlot: "ide"),
                       .layout(slots: whole, active: 0))
        // A Focus on a slot the layout no longer has is not drawn.
        XCTAssertEqual(menuGlyph(running: true, paused: false, layout: layout, focusedSlot: "gone", activeSlot: "ide"),
                       .layout(slots: layout.slots.map(\.rect), active: 0))
    }

    func testOtherStatesHaveTheirOwnGlyph() {
        XCTAssertEqual(menuGlyph(running: true, paused: false, layout: nil, focusedSlot: nil, activeSlot: nil), .free)
        XCTAssertEqual(menuGlyph(running: true, paused: true, layout: layout, focusedSlot: nil, activeSlot: nil), .paused)
        XCTAssertEqual(menuGlyph(running: false, paused: false, layout: layout, focusedSlot: nil, activeSlot: nil), .brand)
    }
}
