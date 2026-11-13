import CoreGraphics
import XCTest
@testable import FremspaceCore

final class PlacementPlanTests: XCTestCase {
    private let builtIn = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let dell = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "DELL")
    private let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)
    private let dellVisible = CGRect(x: 1512, y: -559, width: 3360, height: 1860)

    private func window(_ id: UInt32, title: String = "Tab") -> WindowInfo {
        WindowInfo(id: id, pid: 100, bundleID: "com.brave.Browser", title: title, profile: nil,
                   isStandard: true, isMinimized: false, isFullScreen: false)
    }

    /// `a`: unlocked left half, `b`: locked right half, both for Brave.
    private var layout: Layout {
        Layout(slots: [
            Slot(id: "a", rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: "com.brave.Browser"), locked: false),
            Slot(id: "b", rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: "com.brave.Browser"), locked: true),
        ])
    }

    private var space: SpaceKey { SpaceKey(display: builtIn, spaceIndex: 0) }

    private func frames(_ visible: CGRect) -> [String: CGRect] {
        slotFrames(layout: layout, focus: nil, visible: visible, gap: 8)
    }

    private func input(_ windows: [SeenWindow], held: [UInt32: String] = [:], chosen: [UInt32: String] = [:],
                       skip: Set<UInt32> = [], cannotFit: Set<UInt32> = [], force: Bool = false) -> PlanInput {
        PlanInput(desktops: [space: SpaceSpec(label: "Mail", layout: layout)], visible: [builtIn: visible],
                  windows: windows, held: held.mapValues { HeldSlot(space: space, slotID: $0) }, chosen: chosen,
                  memory: [:], skip: skip, cannotFit: cannotFit,
                  focus: [:], force: force, only: nil, gap: 8, tolerance: 2)
    }

    private let elsewhere = CGRect(x: 300, y: 300, width: 500, height: 400)

    func testNewWindowGetsAMove() {
        let plan = planPlacements(input([SeenWindow(info: window(1), space: space, frame: elsewhere)]))
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.slotID, "a")
        XCTAssertEqual(plan.first?.move?.to, frames(visible)["a"])
        XCTAssertEqual(plan.first?.locked, false)
    }

    func testHeldUnlockedWindowIsNotMovedUnlessForced() {
        let seen = [SeenWindow(info: window(1), space: space, frame: elsewhere)]
        let plan = planPlacements(input(seen, held: [1: "a"]))
        XCTAssertEqual(plan.count, 1)
        XCTAssertNil(plan.first?.move)
        let forced = planPlacements(input(seen, held: [1: "a"], force: true))
        XCTAssertEqual(forced.first?.move?.to, frames(visible)["a"])
    }

    func testASlotOfTheSameNameHeldOnAnotherDesktopIsNotThisOne() {
        // The window held the unlocked `a` of the next desktop and was taken here by hand: this
        // desktop's `a` is another slot, and the window is placed in it like one that opens here.
        var taken = input([SeenWindow(info: window(1), space: space, frame: elsewhere)])
        taken.held = [1: HeldSlot(space: SpaceKey(display: builtIn, spaceIndex: 1), slotID: "a")]
        let plan = planPlacements(taken)
        XCTAssertEqual(plan.first?.slotID, "a")
        XCTAssertEqual(plan.first?.move?.to, frames(visible)["a"])
    }

    func testADesktopWhoseFocusChangedWhileNotShownIsPlacedAgain() {
        // `a` got the Focus while its desktop was not shown: the window that holds it, unlocked,
        // takes the enlarged frame when the desktop is shown, without the pass being forced.
        var shown = input([SeenWindow(info: window(1), space: space, frame: frames(visible)["a"]!)], held: [1: "a"])
        shown.focus = [space: "a"]
        XCTAssertNil(planPlacements(shown).first?.move)
        shown.refocused = [space]
        let enlarged = slotFrames(layout: layout, focus: "a", visible: visible, gap: 8)["a"]
        XCTAssertEqual(planPlacements(shown).first?.move?.to, enlarged)
        XCTAssertNotEqual(enlarged, frames(visible)["a"])
    }

    func testASlotRememberedOnOneDesktopDoesNotChooseOnAnother() {
        // A window titled "Tab" was dropped into `b` on the next desktop: here, where `b` exists
        // too, a new window of that title still goes to the first slot that takes it.
        let other = SpaceKey(display: builtIn, spaceIndex: 1)
        var plan = input([SeenWindow(info: window(1), space: space, frame: elsewhere)])
        plan.memory = [other: [WindowKey(window(1)): "b"]]
        XCTAssertEqual(planPlacements(plan).first?.slotID, "a")
        plan.memory = [space: [WindowKey(window(1)): "b"]]
        XCTAssertEqual(planPlacements(plan).first?.slotID, "b")
    }

    func testHeldLockedWindowOffFrameIsMoved() {
        let b = frames(visible)["b"]!
        let far = planPlacements(input([SeenWindow(info: window(1), space: space, frame: b.offsetBy(dx: 40, dy: 0))],
                                       held: [1: "b"], chosen: [1: "b"]))
        XCTAssertEqual(far.first?.move?.to, b)
        let near = planPlacements(input([SeenWindow(info: window(1), space: space, frame: b.offsetBy(dx: 1, dy: 0))],
                                        held: [1: "b"], chosen: [1: "b"]))
        XCTAssertEqual(near.count, 1)
        XCTAssertNil(near.first?.move)
    }

    func testCannotFitLockedWindowIsLeftUnlessForced() {
        let b = frames(visible)["b"]!
        let seen = [SeenWindow(info: window(1), space: space, frame: b.insetBy(dx: -50, dy: 0))]
        let plan = planPlacements(input(seen, held: [1: "b"], chosen: [1: "b"], cannotFit: [1]))
        XCTAssertNil(plan.first?.move)
        let forced = planPlacements(input(seen, held: [1: "b"], chosen: [1: "b"], cannotFit: [1], force: true))
        XCTAssertEqual(forced.first?.move?.to, b)
    }

    func testSkippedWindowsAreNotPlanned() {
        let plan = planPlacements(input([SeenWindow(info: window(1), space: space, frame: elsewhere)], skip: [1]))
        XCTAssertEqual(plan, [])
    }

    func testOnlyLimitsToOneDesktop() {
        let dellSpace = SpaceKey(display: dell, spaceIndex: 0)
        var both = input([SeenWindow(info: window(1), space: space, frame: elsewhere),
                          SeenWindow(info: window(2), space: dellSpace, frame: elsewhere)])
        both.desktops[dellSpace] = SpaceSpec(label: "Code", layout: layout)
        both.visible[dell] = dellVisible
        XCTAssertEqual(Set(planPlacements(both).map(\.id)), [1, 2])
        both.only = space
        let plan = planPlacements(both)
        XCTAssertEqual(plan.map(\.id), [1])
        XCTAssertEqual(plan.first?.space, space)
    }

    func testChosenSlotSurvivesTitleChange() {
        let plan = planPlacements(input([SeenWindow(info: window(1, title: "Another tab"), space: space, frame: elsewhere)],
                                        held: [1: "a"], chosen: [1: "b"]))
        XCTAssertEqual(plan.first?.slotID, "b")
        XCTAssertEqual(plan.first?.locked, true)
        XCTAssertEqual(plan.first?.move?.to, frames(visible)["b"])
    }
}
