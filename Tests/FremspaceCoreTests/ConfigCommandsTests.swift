import CoreGraphics
import Foundation
import XCTest
@testable import FremspaceCore

final class ConfigCommandsTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)

    private func window(_ app: String, profile: String? = nil) -> WindowInfo {
        WindowInfo(id: 1, pid: 1, bundleID: app, title: "w", profile: profile, isStandard: true, isMinimized: false,
                   isFullScreen: false)
    }

    /// Left half: Outlook; right half: Teams (unlocked).
    private var mailLayout: Layout {
        Layout(slots: [
            Slot(id: "outlook", rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: "com.microsoft.Outlook")),
            Slot(id: "teams", rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: "com.microsoft.teams2"),
                 locked: false),
        ])
    }

    func testLockOnFreeDesktopCreatesALayout() {
        let frame = CGRect(x: 0, y: 33, width: 756, height: 949)
        let result = lockHere(layout: nil, window: window("com.apple.finder"), frame: frame, visible: visible)
        XCTAssertEqual(result?.layout.slots.count, 1)
        XCTAssertEqual(result?.slotID, "finder")
        XCTAssertEqual(result?.layout.slots.first?.rect, UnitRect(x: 0, y: 0, w: 0.5, h: 1))
        XCTAssertEqual(result?.layout.slots.first?.locked, true)
    }

    func testLockAddsALockedSlotWithProfile() {
        // Free right half of a layout with only a left slot.
        let layout = Layout(slots: [mailLayout.slots[0]])
        let frame = CGRect(x: 760, y: 40, width: 748, height: 936)
        let result = lockHere(layout: layout, window: window("com.brave.Browser", profile: "Work"), frame: frame,
                              visible: visible)
        XCTAssertEqual(result?.layout.slots.count, 2)
        let added = result?.layout.slots.first { $0.id == result?.slotID }
        XCTAssertEqual(added?.rule, Rule(bundleID: "com.brave.Browser", profile: "Work"))
        XCTAssertEqual(added?.locked, true)
        XCTAssertEqual(added?.rect, UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))
    }

    func testOverlapJoinsTheSlotOverlappedMost() {
        // Mostly over Teams' half.
        let frame = CGRect(x: 600, y: 33, width: 900, height: 949)
        let result = lockHere(layout: mailLayout, window: window("com.tinyspeck.slackmacgap"), frame: frame, visible: visible)
        XCTAssertEqual(result?.slotID, "teams")
        XCTAssertEqual(result?.layout.slots.count, 2)
        XCTAssertEqual(result?.layout.slots[1].rules.map(\.bundleID), ["com.microsoft.teams2", "com.tinyspeck.slackmacgap"])
    }

    func testAWindowThatOnlyBrushesASlotGetsItsOwn() {
        // One point over Outlook's half, the rest on the free right half.
        let layout = Layout(slots: [mailLayout.slots[0]])
        let frame = CGRect(x: 755, y: 33, width: 757, height: 949)
        let result = lockHere(layout: layout, window: window("com.apple.finder"), frame: frame, visible: visible)
        XCTAssertEqual(result?.slotID, "finder")
        XCTAssertEqual(result?.layout.slots.map(\.rules.count), [1, 1])
        XCTAssertEqual(result?.layout.slots.last?.rect, UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))
        XCTAssertNil(result.flatMap { isValid($0.layout) })
    }

    func testASlotThatWouldSnapOverAnotherIsNotMade() {
        // A slot that ends at 5/8 (set on a larger display), and a window just right of it: the
        // grid of this display pulls the window's left edge to 3/5, over the slot.
        let layout = Layout(slots: [Slot(id: "wide", rect: UnitRect(x: 0, y: 0, w: 0.625, h: 1), rule: Rule(bundleID: "com.example.ide"))])
        let frame = CGRect(x: 950, y: 33, width: 562, height: 949)
        XCTAssertNil(lockHere(layout: layout, window: window("com.apple.finder"), frame: frame, visible: visible))
    }

    func testJoiningTwiceAddsNoDuplicateRule() {
        let frame = CGRect(x: 600, y: 33, width: 900, height: 949)
        let once = lockHere(layout: mailLayout, window: window("com.tinyspeck.slackmacgap"), frame: frame, visible: visible)!
        let twice = lockHere(layout: once.layout, window: window("com.tinyspeck.slackmacgap"), frame: frame, visible: visible)
        XCTAssertEqual(twice?.layout, once.layout)
    }

    func testOneRuleIsWrittenAsRule() throws {
        let json = String(decoding: try JSONEncoder().encode(mailLayout.slots[0]), as: UTF8.self)
        XCTAssertTrue(json.contains("\"rule\""))
        XCTAssertFalse(json.contains("\"rules\""))
    }

    func testRulesRoundTrip() throws {
        var slot = mailLayout.slots[0]
        slot.rules.append(Rule(bundleID: "com.apple.mail"))
        let data = try JSONEncoder().encode(slot)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"rules\""))
        let decoded = try JSONDecoder().decode(Slot.self, from: data)
        XCTAssertEqual(decoded, slot)
    }

    func testMatchesAnyRule() {
        var slot = mailLayout.slots[0]
        slot.rules.append(Rule(bundleID: "com.apple.mail"))
        XCTAssertTrue(matches(slot, window("com.apple.mail")))
        XCTAssertTrue(matches(slot, window("com.microsoft.Outlook")))
        XCTAssertFalse(matches(slot, window("com.apple.finder")))
    }

    func testToggleFocusable() {
        let toggled = toggledFocusable(mailLayout, slot: "teams")
        XCTAssertEqual(toggled.slots[1].focusable, true)
        XCTAssertEqual(toggledFocusable(toggled, slot: "teams").slots[1].focusable, false)
    }
}
