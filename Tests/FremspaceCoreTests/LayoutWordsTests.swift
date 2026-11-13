import XCTest
@testable import FremspaceCore

final class LayoutWordsTests: XCTestCase {
    private let names = ["com.example.ide": "Editor", "com.example.web": "Browser", "com.example.chat": "Messages",
                         "com.example.term": "Terminal"]
    private func name(_ id: String) -> String { names[id] ?? id }
    private let big = DisplayIdentity(vendor: 2, model: 1, serial: 1, name: "Wide")
    private let side = DisplayIdentity(vendor: 3, model: 1, serial: 1, name: "Tall")

    private func slot(_ id: String, _ app: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Slot {
        Slot(id: id, rect: UnitRect(x: x, y: y, w: w, h: h), rule: Rule(bundleID: app))
    }

    /// A large slot on the left with Focus, two stacked on the right.
    private var code: SpaceSpec {
        SpaceSpec(label: "Code", layout: Layout(slots: [
            slot("ide", "com.example.ide", 0, 0, 0.6, 1), slot("web", "com.example.web", 0.6, 0, 0.4, 0.5),
            slot("chat", "com.example.chat", 0.6, 0.5, 0.4, 0.5),
        ]), focusSlot: "ide")
    }

    private var halves: SpaceSpec {
        SpaceSpec(label: "Web", layout: Layout(slots: [
            slot("ide", "com.example.ide", 0, 0, 0.5, 1), slot("web", "com.example.web", 0.5, 0, 0.5, 1),
        ]))
    }

    private func preset(_ id: String) -> [UnitRect] { layoutPresets.first { $0.id == id }?.rects ?? [] }

    /// Two displays, a desktop on each, and a scene that shows both.
    private var night: SharedLayout {
        SharedLayout(name: "Night shift", displays: [
            SharedDisplay(name: "Wide", desktops: [code]), SharedDisplay(name: "Tall", desktops: [SpaceSpec(label: "Talk")]),
        ], scenes: [
            SharedScene(name: "Deep work", desktops: [.init(display: 0, index: 0), .init(display: 1, index: 0)],
                        focus: [.init(display: 0, slotID: "ide")], drawers: [.init(display: 0, edge: .left, open: true)],
                        apps: ["com.example.chat"]),
        ])
    }

    func testADesktopKeptIsCountedInSlotsAppsAndFocus() {
        XCTAssertEqual(layoutCounts(code), "3 slots, 3 apps, Focus")
        XCTAssertEqual(layoutCounts(halves), "2 slots, 2 apps")
        XCTAssertEqual(layoutCounts(SpaceSpec(label: "Rest", layout: Layout(slots: [slot("main", "", 0, 0, 1, 1)]))), "1 slot")
        XCTAssertEqual(layoutCounts(SpaceSpec(label: "Rest")), "free")
    }

    func testADeskIsCountedInDisplaysDesktopsAndScenes() {
        XCTAssertEqual(deskCounts(night), "2 displays, 2 desktops, 1 scene")
        XCTAssertEqual(deskCounts(SharedLayout(name: "One", displays: [SharedDisplay(name: "Wide", desktops: [code])])), "1 desktop")
    }

    func testADrawingIsReadOutSlotBySlot() {
        XCTAssertEqual(layoutInWords(code, appName: name, missing: ["com.example.chat"]),
                       "3 slots: Editor (Focus), Browser, Messages (not on this Mac)")
        XCTAssertEqual(layoutInWords(SpaceSpec(label: "Rest", layout: Layout(slots: [slot("main", "", 0, 0, 1, 1)])), appName: name),
                       "1 slot: an empty slot")
        XCTAssertEqual(layoutInWords(SpaceSpec(label: "Rest"), appName: name), "free: windows float")
    }

    func testAsManySlotsAsShapesKeepTheirAppsLargestFirst() {
        let result = reshaped(code, to: preset("mainAndTwo"), focusOnLargest: true)
        XCTAssertEqual(reshapeInWords(result, from: code, focusOnLargest: true, drawers: 1, appName: name), [
            "Its 3 slots take these shapes. The apps stay, largest slot first: Editor, Browser, Messages.",
            "Focus goes to the largest slot.",
            "The drawer of the display is not touched.",
        ])
    }

    func testShapesLeftOverAreSaidToBeEmptySlotsThatSaveWaitsFor() {
        let result = reshaped(halves, to: preset("mainAndTwo"), focusOnLargest: false)
        XCTAssertEqual(reshapeInWords(result, from: halves, focusOnLargest: false, drawers: 0, appName: name), [
            "Its 2 slots take the largest shapes. The apps stay, largest slot first: Editor, Browser.",
            "1 new slot is empty: Save waits until it has an app.",
        ])
    }

    func testSlotsLeftOverAreSaidToStackAndWhere() {
        let result = reshaped(code, to: preset("sideBySide"), focusOnLargest: false)
        XCTAssertEqual(reshapeInWords(result, from: code, focusOnLargest: false, drawers: 2, appName: name), [
            "Its 3 slots become 2. Messages stacks with Browser in the smallest slot: nothing you placed is dropped.",
            "Focus stays where it was.",
            "The drawers of the display are not touched.",
        ])
    }

    func testAFreeDesktopIsSaidToGetEmptySlots() {
        let free = SpaceSpec(label: "Rest")
        let result = reshaped(free, to: preset("mainAndTwo"), focusOnLargest: true)
        XCTAssertEqual(reshapeInWords(result, from: free, focusOnLargest: true, drawers: 0, appName: name), [
            "It is free now: it gets 3 empty slots, and you choose their apps.",
            "Focus goes to the largest slot.",
        ])
    }

    func testALayoutKeptSaysWhatComesAndWhatLosesItsSlot() {
        let mix = SpaceSpec(label: "Mix", layout: Layout(slots: [
            slot("term", "com.example.term", 0, 0, 0.5, 1), slot("web", "com.example.web", 0.5, 0, 0.5, 1),
        ]), focusSlot: "term")
        XCTAssertEqual(replacementInWords(code, over: mix, drawers: 2, appName: name), [
            "Its layout is replaced by 3 slots with their apps: Editor, Browser, Messages.",
            "Terminal no longer has a slot on this desktop.",
            "Focus comes with it, on Editor.",
            "The drawers of the display are not touched.",
        ])
        XCTAssertEqual(replacementInWords(halves, over: SpaceSpec(label: "Rest"), drawers: 0, appName: name), [
            "It is free now: it gets 2 slots with their apps: Editor, Browser.",
        ])
        // The desktop had Focus and the layout brings none.
        XCTAssertEqual(replacementInWords(halves, over: mix, drawers: 0, appName: name).last, "Its Focus goes: the layout has none.")
    }

    func testASceneOfAFileIsToldWithTheNamesOfTheDisplaysHere() {
        let scene = night.scenes[0]
        XCTAssertEqual(sceneInWords(scene, of: night, displayNames: [0: "Main", 1: "Right"], appName: name),
                       "Main shows Code with Focus, Right shows Talk, Main opens its left drawer, opens Messages")
        // What is on a display left out is not said.
        XCTAssertEqual(sceneInWords(scene, of: night, displayNames: [1: "Right"], appName: name), "Right shows Talk, opens Messages")
        XCTAssertEqual(sceneInWords(scene, of: night, displayNames: [:], appName: name), "Not added: its displays are left out.")
    }

    func testWhatComesWithAFileIsCountedFromTheDisplaysChosen() {
        let desk = Configuration(id: UUID(), name: "Desk", displays: [
            DisplaySpec(identity: big, spaces: [SpaceSpec(label: "One")]), DisplaySpec(identity: side, spaces: [SpaceSpec(label: "Two")]),
        ])
        XCTAssertEqual(importInWords(adding(night, to: desk, onto: [0: big, 1: side]).report, of: night), "Its 2 desktops, 1 scene")
        XCTAssertEqual(importInWords(adding(night, to: desk, onto: [1: side]).report, of: night), "1 of its 2 desktops, 1 scene")
        XCTAssertEqual(importInWords(adding(night, to: desk, onto: [:]).report, of: night),
                       "Nothing yet: choose a display for one of its rows.")
    }

    func testADisplayLeftOutBringsNoAppToMissNorToOpen() {
        var desk = night
        desk.displays[1].desktops = [SpaceSpec(label: "Talk", layout: Layout(slots: [slot("term", "com.example.term", 0, 0, 1, 1)]))]
        XCTAssertEqual(desk.apps(taking: [0, 1]), ["com.example.ide", "com.example.web", "com.example.chat", "com.example.term"])
        // The scene still shows a desktop on the display taken: the app it opens comes too.
        XCTAssertEqual(desk.apps(taking: [0]), ["com.example.ide", "com.example.web", "com.example.chat"])
        XCTAssertEqual(desk.apps(taking: [1]), ["com.example.term", "com.example.chat"])
        XCTAssertEqual(desk.apps(taking: []), [])
        XCTAssertEqual(desk.appsOpenedAtLogin(taking: [1]), ["com.example.term"])
        XCTAssertEqual(desk.appsOpenedAtLogin(taking: [0, 1]), desk.appsOpenedAtLogin)
    }

    func testADisplayOfTheOtherShapeIsSaidInWords() {
        XCTAssertEqual(shapeFitInWords(shapeFit(madeFor: 0.56, here: 1.78)), "Made for a tall display: yours is wide, the rows will be flat.")
        XCTAssertEqual(shapeFitInWords(shapeFit(madeFor: 1.78, here: 0.56)), "Made for a wide display: yours is tall, the columns will be narrow.")
        XCTAssertNil(shapeFitInWords(shapeFit(madeFor: nil, here: 1.78)))
    }
}
