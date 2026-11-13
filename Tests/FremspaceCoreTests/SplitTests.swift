import CoreGraphics
import XCTest
@testable import FremspaceCore

final class SplitTests: XCTestCase {
    private let display = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)
    private var space: SpaceKey { SpaceKey(display: display, spaceIndex: 0) }
    private let layout = Layout(slots: [Slot(id: "web", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: "browser"))])

    private func window(_ id: UInt32) -> SeenWindow {
        SeenWindow(info: WindowInfo(id: id, pid: 100, bundleID: "browser", title: "Tab", profile: nil,
                                    isStandard: true, isMinimized: false, isFullScreen: false),
                   space: space, frame: CGRect(x: 300, y: 300, width: 500, height: 400))
    }

    private func plan(_ ids: [UInt32], split: [UInt32: SplitSide]) -> [UInt32: CGRect] {
        let input = PlanInput(desktops: [space: SpaceSpec(label: "Web", layout: layout)], visible: [display: visible],
                              windows: ids.map(window), held: [:], chosen: [:], memory: [:], skip: [], cannotFit: [],
                              focus: [:], force: false, only: nil, gap: 8, tolerance: 2, split: split)
        return Dictionary(uniqueKeysWithValues: planPlacements(input).map { ($0.id, $0.frame) })
    }

    private var whole: CGRect { slotFrames(layout: layout, focus: nil, visible: visible, gap: 8)["web"] ?? .zero }

    func testTheTwoHalvesFillTheFrameWithTheGapBetweenThem() {
        let frame = CGRect(x: 8, y: 41, width: 1496, height: 933)
        let left = halfFrame(frame, .left, gap: 8), right = halfFrame(frame, .right, gap: 8)
        XCTAssertEqual(left, CGRect(x: 8, y: 41, width: 744, height: 933))
        XCTAssertEqual(right, CGRect(x: 760, y: 41, width: 744, height: 933))
        // An odd width: the right half takes the pixel, nothing is lost.
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 500)
        XCTAssertEqual(halfFrame(odd, .left, gap: 8).maxX + 8, halfFrame(odd, .right, gap: 8).minX)
        XCTAssertEqual(halfFrame(odd, .right, gap: 8).maxX, 1001)
    }

    func testTwoWindowsSplitInASlotTakeHalfOfItEach() {
        let frames = plan([1, 2], split: [1: SplitSide(half: .left, slotID: "web", partner: 2),
                                          2: SplitSide(half: .right, slotID: "web", partner: 1)])
        XCTAssertEqual(frames[1], halfFrame(whole, .left, gap: 8))
        XCTAssertEqual(frames[2], halfFrame(whole, .right, gap: 8))
    }

    func testAThirdWindowOfTheSlotKeepsItWhole() {
        let frames = plan([1, 2, 3], split: [1: SplitSide(half: .left, slotID: "web", partner: 2),
                                             2: SplitSide(half: .right, slotID: "web", partner: 1)])
        XCTAssertEqual(frames[3], whole)
    }

    func testAWindowWhosePartnerIsGoneOrWhoseSlotChangedHasItsSlotWhole() {
        // The partner is not on this desktop any more.
        XCTAssertEqual(plan([1], split: [1: SplitSide(half: .left, slotID: "web", partner: 2)])[1], whole)
        // Split in a slot that is not the one it holds now.
        XCTAssertEqual(plan([1, 2], split: [1: SplitSide(half: .left, slotID: "other", partner: 2)])[1], whole)
    }

    func testAPairIsFoundAgainAfterARestartWhileBothWindowsLive() throws {
        let sides: [UInt32: SplitSide] = [1: SplitSide(half: .left, slotID: "web", partner: 2),
                                          2: SplitSide(half: .right, slotID: "web", partner: 1)]
        let saved = savedSplits(sides, pids: [1: 100, 2: 100])
        XCTAssertEqual(saved, [SavedSplit(left: SavedWindow(id: 1, pid: 100), right: SavedWindow(id: 2, pid: 100), slotID: "web")])
        // Through the state file.
        let state = FremspaceState(splits: saved)
        let back = try JSONDecoder().decode(FremspaceState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(splitSides(back.splits, alive: [1: 100, 2: 100, 9: 300]), sides)
        // One window closed meanwhile, or its id taken by another app's window: no pair.
        XCTAssertEqual(splitSides(saved, alive: [1: 100]), [:])
        XCTAssertEqual(splitSides(saved, alive: [1: 100, 2: 555]), [:])
    }

    func testAStateFileWithoutPairsReadsAsNone() throws {
        let old = try JSONDecoder().decode(FremspaceState.self, from: Data("{}".utf8))
        XCTAssertEqual(old.splits, [])
        // Half a pair (its partner forgotten) is not saved.
        XCTAssertEqual(savedSplits([1: SplitSide(half: .left, slotID: "web", partner: 2)], pids: [1: 100, 2: 100]), [])
    }

    func testABrowsersNewWindowIsTheItemOnCommandN() {
        let browser = [
            MenuShortcut(title: "New Tab", key: "T", commandOnly: true),
            MenuShortcut(title: "New Window", key: "N", commandOnly: true),
            MenuShortcut(title: "New Private Window", key: "N", commandOnly: false),
            MenuShortcut(title: "New Private Window with Tor", key: "N", commandOnly: false),
        ]
        XCTAssertEqual(newWindowItem(browser), 1)
        let french = [
            MenuShortcut(title: "Nouvelle fenêtre de navigation privée", key: "N", commandOnly: false),
            MenuShortcut(title: "Nouvelle fenêtre", key: "n", commandOnly: true),
        ]
        XCTAssertEqual(newWindowItem(french), 1)
    }

    func testAnEditorsNewWindowIsNotItsNewFile() {
        let editor = [
            MenuShortcut(title: "New Text File", key: "N", commandOnly: true),
            MenuShortcut(title: "New File...", key: "N", commandOnly: false),
            MenuShortcut(title: "New Window", key: "N", commandOnly: false),
        ]
        XCTAssertEqual(newWindowItem(editor), 2)
    }

    func testCommandNThatNamesSomethingElseThanAWindowIsNotPressed() {
        // A notes app, a mail app, a calendar: ⌘N makes a thing, not a window.
        XCTAssertNil(newWindowItem([MenuShortcut(title: "New Note", key: "N", commandOnly: true)]))
        XCTAssertNil(newWindowItem([MenuShortcut(title: "Nouveau message", key: "N", commandOnly: true)]))
        // The same app with a window item further down still has it found.
        XCTAssertEqual(newWindowItem([MenuShortcut(title: "New Message", key: "N", commandOnly: true),
                                      MenuShortcut(title: "New Viewer Window", key: "N", commandOnly: false)]), 1)
        // A document app: "New…" alone is a new document, in a window.
        XCTAssertEqual(newWindowItem([MenuShortcut(title: "New\u{2026}", key: "N", commandOnly: true)]), 0)
    }

    func testWithoutAWordForWindowCommandNAloneIsTaken() {
        XCTAssertEqual(newWindowItem([MenuShortcut(title: "Open...", key: "O", commandOnly: true),
                                      MenuShortcut(title: "Neu", key: "N", commandOnly: true)]), 1)
        XCTAssertNil(newWindowItem([MenuShortcut(title: "New Note", key: "N", commandOnly: false)]))
        XCTAssertNil(newWindowItem([]))
    }
}
