import XCTest
@testable import FremspaceCore

final class LayoutPresetsTests: XCTestCase {
    private func slot(_ id: String, _ x: Double, _ w: Double, _ app: String, focusable: Bool = false) -> Slot {
        Slot(id: id, rect: UnitRect(x: x, y: 0, w: w, h: 1), rule: Rule(bundleID: app), focusable: focusable)
    }

    private func preset(_ id: String) -> LayoutPreset {
        layoutPresets.first { $0.id == id }!
    }

    func testEveryPresetIsALayoutTheEditorWouldSaveAndCoversTheDisplay() {
        XCTAssertEqual(Set(layoutPresets.map(\.id)).count, layoutPresets.count)
        for preset in layoutPresets {
            let made = reshaped(SpaceSpec(label: "New"), to: preset.rects, focusOnLargest: false).desktop.layout
            XCTAssertNotNil(made, preset.id)
            XCTAssertNil(made.flatMap(isValid), preset.id)
            let area = preset.rects.reduce(0) { $0 + $1.w * $1.h }
            XCTAssertEqual(area, 1, accuracy: 1e-9, preset.id)
        }
    }

    func testAFreeDesktopGetsEmptySlotsInReadingOrder() {
        let made = reshaped(SpaceSpec(label: "Rest"), to: preset("mainAndTwo").rects, focusOnLargest: false)
        let slots = made.desktop.layout?.slots ?? []
        XCTAssertEqual(slots.map(\.id), ["slot1", "slot2", "slot3"])
        XCTAssertEqual(made.added, ["slot1", "slot2", "slot3"])
        XCTAssertTrue(slots.allSatisfy { $0.rules == [Rule(bundleID: "")] })
        XCTAssertEqual(slots[0].rect.w, 2.0 / 3, accuracy: 1e-9)
        XCTAssertNil(made.desktop.focusSlot)
        XCTAssertTrue(made.merged.isEmpty)
    }

    func testTheSlotsADesktopHadKeepTheirAppsLargestFirst() {
        // The browser has the most room, then the editor, then the notes.
        var notes = slot("notes", 0.8, 0.2, "com.example.notes")
        notes.locked = false
        let desktop = SpaceSpec(label: "Code", layout: Layout(slots: [
            slot("ide", 0, 0.3, "com.example.ide"), slot("web", 0.3, 0.5, "com.example.browser"), notes,
        ]), focusSlot: "ide")
        let made = reshaped(desktop, to: preset("mainAndTwo").rects, focusOnLargest: false)
        let slots = made.desktop.layout?.slots ?? []
        XCTAssertEqual(slots.map(\.id), ["web", "ide", "notes"])
        XCTAssertEqual(slots[0].rect, UnitRect(x: 0, y: 0, w: 2.0 / 3, h: 1))
        XCTAssertEqual(slots[1].rect.y, 0)
        XCTAssertEqual(slots[2].rect.y, 0.5)
        XCTAssertEqual(slots[2].rules, [Rule(bundleID: "com.example.notes")])
        XCTAssertFalse(slots[2].locked)
        XCTAssertTrue(made.added.isEmpty)
        // Not asked for: the Focus stays with its slot, wherever that slot went.
        XCTAssertEqual(made.desktop.focusSlot, "ide")
        XCTAssertNil(isValid(made.desktop.layout!))
    }

    func testFocusOnTheLargestSlotWhenAskedFor() {
        let desktop = SpaceSpec(label: "Code", layout: Layout(slots: [
            slot("ide", 0, 0.3, "com.example.ide"), slot("web", 0.3, 0.7, "com.example.browser"),
        ]), focusSlot: "ide")
        XCTAssertEqual(reshaped(desktop, to: preset("mainAndSide").rects, focusOnLargest: true).desktop.focusSlot, "web")
        // Of two slots as large, the one read first.
        let free = reshaped(SpaceSpec(label: "New"), to: preset("fourCorners").rects, focusOnLargest: true)
        XCTAssertEqual(free.desktop.focusSlot, "slot1")
        XCTAssertEqual(largestSlot(free.desktop.layout!), "slot1")
    }

    func testSlotsLeftOverStackTheirAppsInTheSmallestShape() {
        let desktop = SpaceSpec(label: "Code", layout: Layout(slots: [
            slot("ide", 0, 0.5, "com.example.ide"), slot("web", 0.5, 0.3, "com.example.browser"),
            slot("notes", 0.8, 0.15, "com.example.notes"), slot("spare", 0.95, 0.05, ""),
        ]), focusSlot: "notes")
        let made = reshaped(desktop, to: preset("sideBySide").rects, focusOnLargest: false)
        let slots = made.desktop.layout?.slots ?? []
        XCTAssertEqual(slots.map(\.id), ["ide", "web"])
        XCTAssertEqual(slots[1].rules.map(\.bundleID), ["com.example.browser", "com.example.notes"])
        XCTAssertEqual(made.merged, ["notes", "spare"])
        XCTAssertEqual(made.mergedInto, "web")
        // Its slot is gone: the desktop has no Focus rather than one on a slot that is not there.
        XCTAssertNil(made.desktop.focusSlot)
    }

    func testANewSlotNeverTakesANameInUse() {
        let desktop = SpaceSpec(label: "Code", layout: Layout(slots: [slot("slot2", 0, 1, "com.example.ide")]))
        let made = reshaped(desktop, to: preset("thirds").rects, focusOnLargest: false)
        XCTAssertEqual(Set(made.desktop.layout?.slots.map(\.id) ?? []).count, 3)
        XCTAssertEqual(made.added.count, 2)
        XCTAssertFalse(made.added.contains("slot2"))
    }

    func testALayoutForATallDisplayIsToldOnAWideOne() {
        XCTAssertEqual(shapeFit(madeFor: 0.56, here: 1.78), .madeForTall)
        XCTAssertEqual(shapeFit(madeFor: 2.39, here: 0.56), .madeForWide)
        XCTAssertEqual(shapeFit(madeFor: 2.39, here: 1.78), .fits)
        XCTAssertEqual(shapeFit(madeFor: nil, here: 1.78), .fits)
    }
}
