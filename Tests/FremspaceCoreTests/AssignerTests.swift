import XCTest
@testable import FremspaceCore

final class AssignerTests: XCTestCase {
    private func window(_ id: UInt32, _ bundleID: String = "com.brave.Browser", title: String = "Tab",
                        profile: String? = nil, isStandard: Bool = true, isMinimized: Bool = false,
                        isFullScreen: Bool = false) -> WindowInfo {
        WindowInfo(id: id, pid: 100, bundleID: bundleID, title: title, profile: profile,
                   isStandard: isStandard, isMinimized: isMinimized, isFullScreen: isFullScreen)
    }

    private func slot(_ id: String, _ bundleID: String = "com.brave.Browser", profile: String? = nil) -> Slot {
        Slot(id: id, rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: bundleID, profile: profile))
    }

    func testFirstMatchingSlotWins() {
        let layout = Layout(slots: [slot("a"), slot("b")])
        let result = assign(windows: [window(1)], layout: layout, memory: [:])
        XCTAssertEqual(result, Assignment(placed: [1: "a"], unmatched: []))
    }

    func testMemoryWinsOverOrder() {
        let layout = Layout(slots: [slot("a"), slot("b")])
        let w = window(1)
        let result = assign(windows: [w], layout: layout, memory: [WindowKey(w): "b"])
        XCTAssertEqual(result.placed, [1: "b"])
    }

    func testMemoryForMissingSlotFallsBack() {
        let layout = Layout(slots: [slot("a"), slot("b")])
        let w = window(1)
        let result = assign(windows: [w], layout: layout, memory: [WindowKey(w): "gone"])
        XCTAssertEqual(result.placed, [1: "a"])
    }

    func testProfileMustMatch() {
        let layout = Layout(slots: [slot("work", profile: "Boulot")])
        let result = assign(windows: [window(1, profile: "Perso")], layout: layout, memory: [:])
        XCTAssertEqual(result, Assignment(placed: [:], unmatched: [1]))
    }

    func testSeveralWindowsStackInOneSlot() {
        let layout = Layout(slots: [slot("ide", "com.microsoft.VSCode")])
        let windows = [1, 2, 3].map { window($0, "com.microsoft.VSCode") }
        let result = assign(windows: windows, layout: layout, memory: [:])
        XCTAssertEqual(result.placed, [1: "ide", 2: "ide", 3: "ide"])
        XCTAssertEqual(result.unmatched, [])
    }

    func testSkipsMinimizedAndFullScreen() {
        let layout = Layout(slots: [slot("a")])
        let windows = [window(1, isMinimized: true), window(2, isFullScreen: true), window(3, isStandard: false),
                       window(4, "com.apple.finder", isMinimized: true)]
        let result = assign(windows: windows, layout: layout, memory: [:])
        XCTAssertEqual(result, Assignment(placed: [:], unmatched: []))
    }

    func testTitleContainsIsCaseInsensitive() {
        var rule = Rule(bundleID: "com.brave.Browser")
        rule.titleContains = "jira"
        XCTAssertTrue(matches(rule, window(1, title: "PROJ-12 - JIRA")))
        XCTAssertFalse(matches(rule, window(2, title: "Inbox")))
    }

    func testFixedSizeWindowIsNotManageable() {
        // Outlook's reminder is a standard window whose size cannot change: put in Outlook's slot it
        // only moved to the slot's corner (2026-11-09). It keeps its own place.
        var reminder = WindowInfo(id: 1730, pid: 1, bundleID: "com.microsoft.Outlook", title: "1 Reminder",
                                  profile: nil, isStandard: true, isMinimized: false, isFullScreen: false)
        reminder.isFixedSize = true
        XCTAssertFalse(reminder.isManageable)
        let layout = Layout(slots: [slot("mail", "com.microsoft.Outlook")])
        XCTAssertEqual(assign(windows: [reminder], layout: layout, memory: [:]), Assignment(placed: [:], unmatched: []))
    }

    func testBrowserPopupIsNotManageable() {
        // A site's popup (OAuth, ticket editor) is a standard Brave window without a tab strip: it
        // keeps its own size instead of filling the Brave slot.
        var popup = WindowInfo(id: 9, pid: 1, bundleID: "com.brave.Browser", title: "login.example.com/...",
                               profile: nil, isStandard: true, isMinimized: false, isFullScreen: false)
        popup.isPopup = true
        XCTAssertFalse(popup.isManageable)
        XCTAssertTrue(isTabbedBrowser("com.brave.Browser"))
        XCTAssertTrue(isTabbedBrowser("com.google.Chrome"))
        XCTAssertFalse(isTabbedBrowser("com.microsoft.VSCode"))
    }

    /// A live window the user dropped in slot b stays in b when its title changes (Brave switching
    /// tabs): the slot chosen for that window id wins over the title-keyed memory and over order.
    func testChosenSlotSurvivesTitleChange() {
        let layout = Layout(slots: [slot("a"), slot("b")])
        let before = window(1, title: "Inbox")
        let after = window(1, title: "Release notes")
        let result = assign(windows: [after], layout: layout, memory: [WindowKey(before): "b"], chosen: [1: "b"])
        XCTAssertEqual(result.placed[1], "b")
        let gone = assign(windows: [after], layout: Layout(slots: [slot("a")]), memory: [:], chosen: [1: "b"])
        XCTAssertEqual(gone.placed[1], "a", "a chosen slot that no longer exists falls back")
    }
}
