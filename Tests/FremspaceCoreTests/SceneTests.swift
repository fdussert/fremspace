import XCTest
@testable import FremspaceCore

final class SceneTests: XCTestCase {
    private let laptop = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let big = DisplayIdentity(vendor: 2, model: 1, serial: 1, name: "DELL (1)")
    private func on(_ display: DisplayIdentity, _ index: Int) -> ConfiguredDesktop { ConfiguredDesktop(display: display, index: index) }
    private var meeting: Scene { Scene(id: UUID(), name: "Meeting", desktops: [on(laptop, 3), on(big, 1)]) }

    func testASceneNamesOneDesktopPerDisplay() {
        var scene = meeting
        XCTAssertEqual(scene.desktop(on: big), 1)
        scene.set(2, on: big)
        XCTAssertEqual(scene.desktops, [on(laptop, 3), on(big, 2)])
        scene.set(nil, on: laptop)
        XCTAssertEqual(scene.desktops, [on(big, 2)])
        XCTAssertNil(scene.desktop(on: laptop))
    }

    func testScenesAreWrittenOnlyWhenThereAreSome() throws {
        let plain = Configuration(id: UUID(), name: "Desk", displays: [])
        let plainText = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        XCTAssertFalse(plainText.contains("scenes"))
        let plainBack = try JSONDecoder().decode(Configuration.self, from: Data(plainText.utf8))
        XCTAssertEqual(plainBack, plain)
        let with = Configuration(id: UUID(), name: "Desk", displays: [], scenes: [meeting])
        let back = try JSONDecoder().decode(Configuration.self, from: try JSONEncoder().encode(with))
        XCTAssertEqual(back, with)
    }

    func testRemovingADesktopShiftsTheLaterOnesAndDropsItFromItsScenes() {
        let after = scenes([meeting], afterRemovingDesktop: 1, of: laptop)
        XCTAssertEqual(after[0].desktops, [on(laptop, 2), on(big, 1)])
        let gone = scenes([meeting], afterRemovingDesktop: 1, of: big)
        XCTAssertEqual(gone[0].desktops, [on(laptop, 3)])
    }

    func testASceneNoLongerGivesFocusToASlotThatIsGone() {
        var scene = meeting
        scene.setFocus("web", on: big)
        scene.setFocus("mail", on: laptop)
        // Another desktop of the display, or a slot the scene does not name: nothing to forget.
        XCTAssertEqual(scenes([scene], afterRemovingSlots: ["web"], ofDesktop: 0, of: big), [scene])
        XCTAssertEqual(scenes([scene], afterRemovingSlots: ["notes"], ofDesktop: 1, of: big), [scene])
        let cleaned = scenes([scene], afterRemovingSlots: ["web", "notes"], ofDesktop: 1, of: big)[0]
        XCTAssertNil(cleaned.focus(on: big))
        XCTAssertEqual(cleaned.focus(on: laptop), "mail")
        XCTAssertEqual(cleaned.desktops, scene.desktops)
    }

    func testWhateverNamedASlotThatIsGoneForgetsIt() {
        var scene = meeting
        scene.setFocus("web", on: big)
        let desk = Configuration(id: UUID(), name: "Desk", displays: [
            DisplaySpec(identity: big, spaces: [SpaceSpec(label: "Mail"), SpaceSpec(label: "Web", focusSlot: "web")]),
        ], scenes: [scene])
        let after = forgetting(slots: ["web"], ofDesktop: 1, of: big, in: desk)
        XCTAssertNil(after.displays[0].spaces[1].focusSlot)
        XCTAssertNil(after.scenes[0].focus(on: big))
        // A slot of that name on another desktop keeps what names it.
        XCTAssertEqual(forgetting(slots: ["web"], ofDesktop: 0, of: big, in: desk), desk)
        XCTAssertEqual(forgetting(slots: [], ofDesktop: 1, of: big, in: desk), desk)
    }

    func testMovingADesktopKeepsTheScenesOnTheSameDesktops() {
        // Desktop 3 of the laptop goes first: the scene follows it; the big display is untouched.
        let after = scenes([meeting], afterMovingDesktop: 3, to: 0, of: laptop)
        XCTAssertEqual(after[0].desktops, [on(laptop, 0), on(big, 1)])
        let pushed = scenes([meeting], afterMovingDesktop: 0, to: 3, of: laptop)
        XCTAssertEqual(pushed[0].desktops, [on(laptop, 2), on(big, 1)])
    }

    func testASceneShowsWhatIsThereAndNotShownTheKeyboardDisplayLast() {
        let all: Set<ConfiguredDesktop> = [on(laptop, 3), on(big, 1)]
        XCTAssertEqual(sceneOrder(meeting, available: all, shown: [], keyboardOn: laptop), [on(big, 1), on(laptop, 3)])
        XCTAssertEqual(sceneOrder(meeting, available: all, shown: [], keyboardOn: nil), [on(laptop, 3), on(big, 1)])
        XCTAssertEqual(sceneOrder(meeting, available: all, shown: [on(big, 1)], keyboardOn: big), [on(laptop, 3)])
        XCTAssertEqual(sceneOrder(meeting, available: [on(big, 1)], shown: [], keyboardOn: nil), [on(big, 1)])
    }


    // MARK: - Beyond the desktops

    private func configuration(drawer: Bool = true) -> Configuration {
        func slot(_ id: String, focusable: Bool) -> Slot {
            var slot = Slot(id: id, rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: "com.example.\(id)"))
            slot.focusable = focusable
            return slot
        }
        let call = SpaceSpec(label: "Call", layout: Layout(slots: [slot("call", focusable: true), slot("notes", focusable: false)]))
        let free = SpaceSpec(label: "Rest", layout: nil)
        var bigSpec = DisplaySpec(identity: big, spaces: [free, call])
        if drawer {
            bigSpec.drawers = [DrawerSpec(edge: .left, size: 0.3, layout: DrawerLayout(slots: []))]
        }
        return Configuration(id: UUID(), name: "Desk", displays: [
            DisplaySpec(identity: laptop, spaces: [free, free, free, free]), bigSpec,
        ])
    }

    func testWhatASceneDoesBeyondTheDesktopsIsWrittenOnlyWhenThereIsSome() throws {
        let scene = meeting
        let plain = String(decoding: try JSONEncoder().encode(scene), as: UTF8.self)
        XCTAssertFalse(plain.contains("focus") || plain.contains("drawers") || plain.contains("apps"))
        // A scene written before: only its desktops.
        let old = try JSONDecoder().decode(Scene.self, from: Data(plain.utf8))
        XCTAssertEqual(old, scene)
        var full = scene
        full.setFocus("call", on: big)
        full.setDrawer(true, edge: .left, on: big)
        full.apps = ["com.example.call"]
        let back = try JSONDecoder().decode(Scene.self, from: try JSONEncoder().encode(full))
        XCTAssertEqual(back, full)
        XCTAssertEqual(back.focus(on: big), "call")
        XCTAssertEqual(back.drawer(.left, on: big), true)
        XCTAssertNil(back.drawer(.right, on: big))
    }

    func testTheFocusOfASceneGoesWithTheDesktopItWasOn() {
        var scene = meeting
        scene.setFocus("call", on: big)
        scene.set(1, on: big)
        XCTAssertEqual(scene.focus(on: big), "call")
        scene.set(0, on: big)
        XCTAssertNil(scene.focus(on: big))
        scene.set(1, on: big)
        scene.setFocus("call", on: big)
        let gone = scenes([scene], afterRemovingDesktop: 1, of: big)
        XCTAssertEqual(gone[0].focus, [])
        let kept = scenes([scene], afterRemovingDesktop: 0, of: big)
        XCTAssertEqual(kept[0].focus(on: big), "call")
    }

    func testASceneGivesFocusToASlotThatFocusEnlargesUnlessItHasItAlready() {
        var scene = meeting
        scene.setFocus("call", on: big)
        let all: Set<ConfiguredDesktop> = [on(laptop, 3), on(big, 1)]
        let steps = sceneFocusSteps(scene, in: configuration(), available: all) { _ in nil }
        XCTAssertEqual(steps, [SceneChanges.Focus(desktop: on(big, 1), slotID: "call", was: nil)])
        XCTAssertEqual(sceneFocusSteps(scene, in: configuration(), available: all) { _ in "call" }, [])
        // The desktop is not there (fewer desktops than configured): nothing.
        XCTAssertEqual(sceneFocusSteps(scene, in: configuration(), available: [on(laptop, 3)]) { _ in nil }, [])
        // A slot Focus does not enlarge, or one that is gone: nothing.
        scene.setFocus("notes", on: big)
        XCTAssertEqual(sceneFocusSteps(scene, in: configuration(), available: all) { _ in nil }, [])
        scene.setFocus("gone", on: big)
        XCTAssertEqual(sceneFocusSteps(scene, in: configuration(), available: all) { _ in nil }, [])
    }

    func testASceneMovesOnlyTheDrawersThatAreTheOtherWay() {
        var scene = meeting
        scene.setDrawer(true, edge: .left, on: big)
        scene.setDrawer(false, edge: .right, on: big)
        // The display has no right drawer; the left one is closed.
        XCTAssertEqual(sceneDrawerSteps(scene, in: configuration()) { _, _ in false },
                       [SceneDrawer(display: big, edge: .left, open: true)])
        XCTAssertEqual(sceneDrawerSteps(scene, in: configuration()) { _, _ in true }, [])
        XCTAssertEqual(sceneDrawerSteps(scene, in: configuration(drawer: false)) { _, _ in false }, [])
    }

    func testLeavingASceneGivesBackWhatItChangedAndThatIsStillSo() {
        let changes = SceneChanges(focus: [SceneChanges.Focus(desktop: on(big, 1), slotID: "call", was: "notes")],
                                   drawers: [SceneDrawer(display: big, edge: .left, open: true)])
        let undo = sceneUndo(changes, focused: { _ in "call" }, isOpen: { _, _ in true })
        XCTAssertEqual(undo.focus, [FocusSetting(desktop: on(big, 1), slotID: "notes")])
        XCTAssertEqual(undo.drawers, [SceneDrawer(display: big, edge: .left, open: false)])
        // The owner took Focus off and closed the drawer meanwhile: both are theirs.
        let nothing = sceneUndo(changes, focused: { _ in nil }, isOpen: { _, _ in false })
        XCTAssertEqual(nothing.focus, [])
        XCTAssertEqual(nothing.drawers, [])
    }

    func testAskingForASceneAgainWhileItIsShownLeavesIt() {
        let scene = meeting
        let all: Set<ConfiguredDesktop> = [on(laptop, 3), on(big, 1)]
        XCTAssertEqual(sceneAction(scene, inEffect: nil, available: all, shown: all), .enter)
        XCTAssertEqual(sceneAction(scene, inEffect: scene.id, available: all, shown: all), .leave)
        // The owner went to another desktop: asking again goes back to the scene.
        XCTAssertEqual(sceneAction(scene, inEffect: scene.id, available: all, shown: [on(big, 1)]), .enter)
        // A desktop that is not there does not count.
        XCTAssertEqual(sceneAction(scene, inEffect: scene.id, available: [on(big, 1)], shown: [on(big, 1)]), .leave)
        XCTAssertEqual(sceneAction(scene, inEffect: UUID(), available: all, shown: all), .enter)
    }

    func testLeavingASceneGoesBackToTheDesktopsItsDisplaysShowedBefore() {
        let all: Set<ConfiguredDesktop> = [on(laptop, 0), on(laptop, 3), on(big, 0), on(big, 1)]
        // The laptop showed desktop 1, the big display a full-screen app: only the laptop can go back.
        let switches = sceneSwitches([on(laptop, 3), on(big, 1)], shown: [on(laptop, 0)])
        XCTAssertEqual(switches, [SceneChanges.Switch(from: on(laptop, 0), to: on(laptop, 3))])
        let changes = SceneChanges(switches: [SceneChanges.Switch(from: on(laptop, 0), to: on(laptop, 3)),
                                              SceneChanges.Switch(from: on(big, 0), to: on(big, 1))])
        XCTAssertFalse(changes.isEmpty)
        let shown: Set<ConfiguredDesktop> = [on(laptop, 3), on(big, 1)]
        XCTAssertEqual(sceneReturn(changes, available: all, shown: shown, keyboardOn: laptop), [on(big, 0), on(laptop, 0)])
        // The desktop it came from is gone (fewer desktops): that display stays.
        XCTAssertEqual(sceneReturn(changes, available: [on(laptop, 3), on(big, 0), on(big, 1)], shown: shown, keyboardOn: nil), [on(big, 0)])
        // The owner went elsewhere on a display since: it stays where the owner put it.
        XCTAssertEqual(sceneReturn(changes, available: all, shown: [on(laptop, 3), on(big, 0)], keyboardOn: nil), [on(laptop, 0)])
    }

    func testADrawerASceneOpenedClosesWhenItsDisplayGoesToAnotherDesktop() {
        let opened = SceneDrawer(display: big, edge: .left, open: true)
        let changes = SceneChanges(drawers: [opened, SceneDrawer(display: big, edge: .right, open: false)])
        let scene = [on(laptop, 3), on(big, 1)]
        XCTAssertEqual(sceneDrawersLeftBehind(changes, desktops: scene, shown: [on(laptop, 3), on(big, 1)]), [])
        // The owner went to another desktop of the big display; the laptop does not matter.
        XCTAssertEqual(sceneDrawersLeftBehind(changes, desktops: scene, shown: [on(laptop, 0), on(big, 0)]), [opened])
        // A full-screen app on the display: its desktop is not shown either.
        XCTAssertEqual(sceneDrawersLeftBehind(changes, desktops: scene, shown: [on(laptop, 3)]), [opened])
        // The scene names no desktop for that display: the drawer has none to leave.
        XCTAssertEqual(sceneDrawersLeftBehind(changes, desktops: [on(laptop, 3)], shown: [on(big, 0)]), [])
    }

    func testASceneShownAgainKeepsWhatThingsWereLikeBeforeIt() {
        let first = SceneChanges(focus: [SceneChanges.Focus(desktop: on(big, 1), slotID: "call", was: "notes")])
        let again = SceneChanges(focus: [SceneChanges.Focus(desktop: on(big, 1), slotID: "call", was: nil)],
                                 drawers: [SceneDrawer(display: big, edge: .left, open: true)])
        let merged = first.merging(again)
        // Where a display came from the first time is where it goes back to.
        let came = SceneChanges(switches: [SceneChanges.Switch(from: on(big, 0), to: on(big, 1))])
        let later = SceneChanges(switches: [SceneChanges.Switch(from: on(big, 2), to: on(big, 1)),
                                            SceneChanges.Switch(from: on(laptop, 0), to: on(laptop, 3))])
        XCTAssertEqual(came.merging(later).switches, [SceneChanges.Switch(from: on(big, 0), to: on(big, 1)),
                                                      SceneChanges.Switch(from: on(laptop, 0), to: on(laptop, 3))])
        XCTAssertEqual(merged.focus, [SceneChanges.Focus(desktop: on(big, 1), slotID: "call", was: "notes")])
        XCTAssertEqual(merged.drawers, [SceneDrawer(display: big, edge: .left, open: true)])
        XCTAssertTrue(SceneChanges().isEmpty)
    }

    func testASceneOpensItsAppsThatAreNotRunningEachOnce() {
        var scene = meeting
        scene.apps = ["com.example.call", "com.example.notes", "com.example.call", ""]
        XCTAssertEqual(sceneAppsToOpen(scene, running: ["com.example.notes"]), ["com.example.call"])
    }
}
