import XCTest
@testable import FremspaceCore

final class FocusStateTests: XCTestCase {
    private let display = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "Left")

    func testFocusTogglesPerSpace() {
        let a = SpaceKey(display: display, spaceIndex: 0)
        let b = SpaceKey(display: display, spaceIndex: 1)
        var state = FocusState()
        XCTAssertEqual(state.toggle(a, slot: "ide"), "ide")
        XCTAssertEqual(state.slot(a), "ide")
        XCTAssertNil(state.slot(b))
        XCTAssertNil(state.toggle(a, slot: "ide"))
        XCTAssertNil(state.slot(a))
    }

    func testFocusFollowsItsConfiguredDesktopWhenTheDesktopsAreReordered() {
        let configuration = UUID()
        let code = ConfiguredDesktop(display: display, index: 1)
        let kept = [FocusedSlot(configurationID: configuration, desktop: code, slotID: "ide")]
        // The configured desktop is the second real one, then macOS moves it first.
        var positions = [code: SpaceKey(display: display, spaceIndex: 1)]
        var state = focusState(from: kept, configurationID: configuration, real: { positions[$0] }, hasSlot: { _, _ in true })
        XCTAssertEqual(state.all, [SpaceKey(display: display, spaceIndex: 1): "ide"])
        positions[code] = SpaceKey(display: display, spaceIndex: 0)
        state = focusState(from: kept, configurationID: configuration, real: { positions[$0] }, hasSlot: { _, _ in true })
        XCTAssertEqual(state.all, [SpaceKey(display: display, spaceIndex: 0): "ide"])
    }

    func testFocusOfAnotherConfigurationOfAMissingDesktopOrOfASlotThatIsGoneIsNotGiven() {
        let desk = UUID(), laptop = UUID()
        let first = ConfiguredDesktop(display: display, index: 0), second = ConfiguredDesktop(display: display, index: 1)
        let kept = [FocusedSlot(configurationID: desk, desktop: first, slotID: "main"),
                    FocusedSlot(configurationID: laptop, desktop: first, slotID: "gone"),
                    FocusedSlot(configurationID: laptop, desktop: second, slotID: "main")]
        // The laptop alone: the Focus of the desk does not land on its first desktop, a slot
        // that is no longer in the layout is not in Focus, and its second desktop is not there.
        let state = focusState(from: kept, configurationID: laptop,
                               real: { $0 == first ? SpaceKey(display: self.display, spaceIndex: 0) : nil },
                               hasSlot: { _, slot in slot != "gone" })
        XCTAssertEqual(state.all, [:])
    }

    func testTheFocusOfADesktopThatIsNotThereAndOfOtherConfigurationsIsKept() {
        let desk = UUID(), laptop = UUID()
        let first = ConfiguredDesktop(display: display, index: 0), second = ConfiguredDesktop(display: display, index: 1)
        let other = FocusedSlot(configurationID: desk, desktop: first, slotID: "main")
        let away = FocusedSlot(configurationID: laptop, desktop: second, slotID: "web")
        let before = FocusedSlot(configurationID: laptop, desktop: first, slotID: "ide")
        var focus = FocusState()
        focus.set(SpaceKey(display: display, spaceIndex: 0), slot: "mail")
        let kept = focusToKeep(focus, kept: [other, away, before], configurationID: laptop,
                               configured: { $0.spaceIndex == 0 ? first : nil },
                               real: { $0 == first ? SpaceKey(display: self.display, spaceIndex: 0) : nil })
        XCTAssertEqual(kept, [other, away, FocusedSlot(configurationID: laptop, desktop: first, slotID: "mail")])
        // Focus taken off: only the desktop that is there loses it.
        focus.set(SpaceKey(display: display, spaceIndex: 0), slot: nil)
        XCTAssertEqual(focusToKeep(focus, kept: kept, configurationID: laptop, configured: { $0.spaceIndex == 0 ? first : nil },
                                   real: { $0 == first ? SpaceKey(display: self.display, spaceIndex: 0) : nil }), [other, away])
    }

    func testFocusSwitchesToAnotherSlot() {
        let a = SpaceKey(display: display, spaceIndex: 0)
        var state = FocusState()
        _ = state.toggle(a, slot: "ide")
        XCTAssertEqual(state.toggle(a, slot: "web"), "web")
        XCTAssertEqual(state.slot(a), "web")
    }

    private func codeSpace(webFocusable: Bool, focusSlot: String? = "ide") -> SpaceSpec {
        let rect = UnitRect(x: 0, y: 0, w: 0.5, h: 1)
        var web = Slot(id: "web", rect: rect, rule: Rule(bundleID: "com.brave.Browser"))
        web.focusable = webFocusable
        let layout = Layout(slots: [
            Slot(id: "ide", rect: rect, rule: Rule(bundleID: "com.microsoft.VSCode")),
            web,
        ])
        return SpaceSpec(label: "Code", layout: layout, focusSlot: focusSlot)
    }

    func testTargetIsTheFrontmostFocusableSlot() {
        XCTAssertEqual(focusTarget(in: codeSpace(webFocusable: true), frontmostSlot: "web"), "web")
    }

    func testTargetFallsBackToTheDefaultFocusSlot() {
        XCTAssertEqual(focusTarget(in: codeSpace(webFocusable: false), frontmostSlot: "web"), "ide")
        XCTAssertEqual(focusTarget(in: codeSpace(webFocusable: true), frontmostSlot: nil), "ide")
    }

    func testNoTargetWithoutFocusSlots() {
        XCTAssertNil(focusTarget(in: codeSpace(webFocusable: false, focusSlot: nil), frontmostSlot: "web"))
        XCTAssertEqual(focusTarget(in: codeSpace(webFocusable: true, focusSlot: nil), frontmostSlot: "web"), "web")
        XCTAssertNil(focusTarget(in: SpaceSpec(label: "Free", focusSlot: "ide"), frontmostSlot: "ide"))
    }

    /// Three columns: `left` (not enlarged), `middle` and `right`.
    private func columns(middle: Bool, right: Bool, focusSlot: String? = nil) -> SpaceSpec {
        func slot(_ id: String, _ x: Double, _ focusable: Bool) -> Slot {
            var slot = Slot(id: id, rect: UnitRect(x: x, y: 0, w: 1.0 / 3, h: 1), rule: Rule(bundleID: id))
            slot.focusable = focusable
            return slot
        }
        // The right one first in the file: the order of the file is not the order on screen.
        return SpaceSpec(label: "Web", layout: Layout(slots: [slot("right", 2.0 / 3, right), slot("left", 0, false), slot("middle", 1.0 / 3, middle)]),
                         focusSlot: focusSlot)
    }

    func testSeveralSlotsCanBeEnlargedEachFromItsOwnWindow() {
        let space = columns(middle: true, right: true)
        XCTAssertEqual(focusTarget(in: space, frontmostSlot: "middle"), "middle")
        XCTAssertEqual(focusTarget(in: space, frontmostSlot: "right"), "right")
    }

    func testFromAWindowThatIsInNoneOfThemTheOneFurthestLeftIsEnlarged() {
        let space = columns(middle: true, right: true)
        XCTAssertEqual(focusTarget(in: space, frontmostSlot: "left"), "middle")
        XCTAssertEqual(focusTarget(in: space, frontmostSlot: nil), "middle")
        XCTAssertEqual(focusTarget(in: columns(middle: false, right: true), frontmostSlot: "left"), "right")
    }

    func testTheFocusSlotOfAnOlderFileIsOneOfThem() {
        let old = columns(middle: true, right: false, focusSlot: "right")
        XCTAssertEqual(focusSlots(old).map(\.id).sorted(), ["middle", "right"])
        XCTAssertEqual(focusTarget(in: old, frontmostSlot: "right"), "right")
    }

    func testSwitchingFocusForASlotLeavesTheOthersAsTheyWere() {
        let old = columns(middle: true, right: false, focusSlot: "right")
        let off = settingFocus(old, slot: "right", on: false)
        XCTAssertEqual(focusSlots(off).map(\.id), ["middle"])
        XCTAssertNil(off.focusSlot)
        let on = settingFocus(old, slot: "left", on: true)
        XCTAssertEqual(focusSlots(on).map(\.id).sorted(), ["left", "middle", "right"])
        XCTAssertNil(on.focusSlot)
        XCTAssertEqual(settingFocus(SpaceSpec(label: "Free"), slot: "x", on: true), SpaceSpec(label: "Free"))
    }

    func testFocusableDefaultsToFalseWhenDecoding() throws {
        let json = #"{"id":"web","rect":{"x":0,"y":0,"w":1,"h":1},"rule":{"bundleID":"b"}}"#
        let slot = try JSONDecoder().decode(Slot.self, from: Data(json.utf8))
        XCTAssertFalse(slot.focusable)
    }

    func testAFocusFoundAgainIsSetWithoutToggling() {
        let space = SpaceKey(display: DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "DELL"), spaceIndex: 0)
        var focus = FocusState()
        focus.set(space, slot: "ide")
        focus.set(space, slot: "ide")
        XCTAssertEqual(focus.slot(space), "ide")
        XCTAssertEqual(focus.all, [space: "ide"])
        // The hotkey then turns it off, as if it had never stopped.
        XCTAssertNil(focus.toggle(space, slot: "ide"))
        XCTAssertTrue(focus.all.isEmpty)
    }
}
