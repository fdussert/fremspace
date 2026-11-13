import XCTest
@testable import FremspaceCore

final class PreviewsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func slot(_ id: String, _ app: String, x: Double = 0, w: Double = 1) -> Slot {
        Slot(id: id, rect: UnitRect(x: x, y: 0, w: w, h: 1), rule: Rule(bundleID: app))
    }

    func testAWindowIsCapturedOnceWhileItsPictureIsFresh() {
        var ledger = PreviewLedger(freshFor: 1.5)
        XCTAssertEqual(ledger.due([7, 3, 7, 9], now: start), [7, 3, 9])
        ledger.took(7, at: start)
        ledger.took(3, at: start)
        XCTAssertEqual(ledger.due([7, 3, 9], now: start.addingTimeInterval(1)), [9])
        XCTAssertEqual(ledger.due([7, 3, 9], now: start.addingTimeInterval(1.5)), [7, 3, 9])
    }

    func testTheWindowsThatAreGoneAreForgotten() {
        var ledger = PreviewLedger()
        ledger.took(1, at: start)
        ledger.took(2, at: start)
        XCTAssertEqual(ledger.keep([2, 5]), [1])
        XCTAssertEqual(ledger.due([1, 2], now: start), [1])
        ledger.forgetAll()
        XCTAssertEqual(ledger.due([1, 2], now: start), [1, 2])
    }

    func testAClosedWindowIsForgottenOnItsOwn() {
        var ledger = PreviewLedger(freshFor: 10)
        let now = Date(timeIntervalSince1970: 1000)
        ledger.took(1, at: now)
        ledger.took(2, at: now)
        ledger.forget(1)
        // Its id may come back for another window: that one is pictured at once.
        XCTAssertEqual(ledger.due([1, 2], now: now.addingTimeInterval(1)), [1])
        XCTAssertEqual(ledger.keep([]), [2])
    }

    func testAPictureKeepsTheWindowsProportionsAndIsNeverEnlarged() {
        XCTAssertEqual(previewSize(of: CGSize(width: 2560, height: 1440), longest: 640), CGSize(width: 640, height: 360))
        XCTAssertEqual(previewSize(of: CGSize(width: 900, height: 1800), longest: 640), CGSize(width: 320, height: 640))
        XCTAssertEqual(previewSize(of: CGSize(width: 400, height: 300), longest: 640), CGSize(width: 400, height: 300))
        XCTAssertEqual(previewSize(of: CGSize(width: 4000, height: 2), longest: 640), CGSize(width: 640, height: 1))
        XCTAssertEqual(previewSize(of: .zero, longest: 640), .zero)
    }

    func testOnlyTheSlotsLeftAsSavedShowAPictureInTheEditor() {
        let saved = SpaceSpec(label: "Code", layout: Layout(slots: [slot("left", "code", w: 0.5), slot("right", "term", x: 0.5, w: 0.5)]))
        XCTAssertEqual(slotsAsSaved(edited: saved, saved: saved), ["left", "right"])

        // The divider moved: neither slot is where its window is.
        var resized = saved
        resized.layout = Layout(slots: [slot("left", "code", w: 0.6), slot("right", "term", x: 0.6, w: 0.4)])
        XCTAssertEqual(slotsAsSaved(edited: resized, saved: saved), [])

        // Another app in one slot: the other keeps its picture.
        var other = saved
        other.layout?.slots[1].rule = Rule(bundleID: "notes")
        XCTAssertEqual(slotsAsSaved(edited: other, saved: saved), ["left"])

        // A slot added by a split has no window yet.
        var split = saved
        split.layout = Layout(slots: [slot("left", "code", w: 0.5), slot("right", "term", x: 0.5, w: 0.25), slot("right-2", "term", x: 0.75, w: 0.25)])
        XCTAssertEqual(slotsAsSaved(edited: split, saved: saved), ["left"])
    }

    func testADesktopThatMovedOrIsNewShowsNoPicture() {
        let saved = SpaceSpec(label: "Code", layout: Layout(slots: [slot("main", "code")]))
        // Desktops reordered: another desktop sits at this position now, with a slot of the same id.
        XCTAssertEqual(slotsAsSaved(edited: SpaceSpec(label: "Web", layout: Layout(slots: [slot("main", "code")])), saved: saved), [])
        XCTAssertEqual(slotsAsSaved(edited: saved, saved: nil), [])
        XCTAssertEqual(slotsAsSaved(edited: saved, saved: SpaceSpec(label: "Code")), [])
        XCTAssertEqual(slotsAsSaved(edited: SpaceSpec(label: "Code"), saved: saved), [])
    }

    func testThePreviewsAreOffUnlessSwitchedOnAndOnlyThenWritten() throws {
        var config = Config(configurations: [])
        XCTAssertFalse(config.windowPreviews)
        let plain = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(plain.contains("windowPreviews"))
        config.windowPreviews = true
        let back = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(config))
        XCTAssertTrue(back.windowPreviews)
    }

    func testPreviewsWithoutScreenRecordingAreSaidWithTheWayToAllowThem() {
        var facts = AttentionFacts()
        XCTAssertEqual(attentionItems(facts), [])
        facts.config.windowPreviews = true
        let items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["previews"])
        XCTAssertEqual(items.first?.level, .warning)
        XCTAssertEqual(items.first?.fix, .openScreenRecordingSettings)
        facts.screenRecording = true
        XCTAssertEqual(attentionItems(facts), [])
    }

    func testTheWindowOnScreenStandsForItsSlotBeforeAMinimisedOneInFrontOfIt() {
        // The window list often gives a minimised window before the one that is shown.
        let minimised = SlotWindow(id: 9, onScreen: false, minimized: true)
        let shown = SlotWindow(id: 4, onScreen: true, minimized: false)
        XCTAssertEqual(slotFront([minimised, shown]), shown)
        // Two on screen: the one in front.
        let behind = SlotWindow(id: 2, onScreen: true, minimized: false)
        XCTAssertEqual(slotFront([minimised, shown, behind]), shown)
    }

    func testOnADesktopThatIsNotShownTheFirstWindowThatIsNotMinimisedStandsForItsSlot() {
        let minimised = SlotWindow(id: 9, onScreen: false, minimized: true)
        let away = SlotWindow(id: 4, onScreen: false, minimized: false)
        XCTAssertEqual(slotFront([minimised, away]), away)
        // Only minimised windows: the slot still has its app, without a picture.
        XCTAssertEqual(slotFront([minimised]), minimised)
        XCTAssertNil(slotFront([]))
    }
}
