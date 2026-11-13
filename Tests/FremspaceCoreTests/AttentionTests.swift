import XCTest
@testable import FremspaceCore

final class AttentionTests: XCTestCase {
    private let laptop = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let big = DisplayIdentity(vendor: 2, model: 1, serial: 1, name: "DELL (1)")
    private let deskID = UUID()

    private func slot(_ id: String, _ app: String) -> Slot {
        Slot(id: id, rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: app))
    }

    /// A desk that runs: two displays, a free desktop, as many desktops as configured.
    private func facts(free: Bool = true) -> AttentionFacts {
        var spaces = [SpaceSpec(label: "Code", layout: Layout(slots: [slot("ide", "code")])),
                      SpaceSpec(label: "Web", layout: Layout(slots: [slot("main", "brave")]))]
        if free { spaces.append(SpaceSpec(label: "The rest")) }
        var facts = AttentionFacts()
        facts.config = Config(configurations: [Configuration(id: deskID, name: "Home desk", displays: [
            DisplaySpec(identity: laptop, spaces: [SpaceSpec(label: "Slack", layout: Layout(slots: [slot("main", "slack")]))]),
            DisplaySpec(identity: big, spaces: spaces),
        ])])
        facts.active = deskID
        facts.desktopCounts = [laptop: 1, big: spaces.count]
        return facts
    }

    func testNothingToSayWhenEverythingRuns() {
        XCTAssertEqual(attentionItems(facts()), [])
    }

    func testWithoutAccessibilityOnlyThatIsSaidAboutNotRunning() {
        var facts = facts()
        facts.accessibility = false
        facts.active = nil
        facts.idle = .other("Accessibility not granted")
        facts.config.hyperKey = true
        let items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["accessibility"])
        XCTAssertEqual(items[0].level, .blocking)
        XCTAssertEqual(items[0].fix, .openAccessibilitySettings)
    }

    func testPausedIsSaidOnceWithTheWayBack() {
        var facts = facts()
        facts.paused = true
        facts.active = nil
        facts.idle = .other("Paused")
        let items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["paused"])
        XCTAssertEqual(items[0].fix, .resume)
    }

    func testNoConfigurationForTheseDisplaysOffersToMakeOne() {
        var facts = facts()
        facts.active = nil
        facts.idle = .noConfiguration
        var items = attentionItems(facts)
        XCTAssertEqual(items.map(\.title), ["No configuration for the displays connected now"])
        XCTAssertEqual(items[0].fix, .newConfiguration)
        facts.config.configurations = []
        items = attentionItems(facts)
        XCTAssertEqual(items.map(\.title), ["No configuration yet"])
    }

    func testADisplayShortOfDesktopsOffersToAddThem() {
        var facts = facts()
        facts.desktopCounts[big] = 1
        let items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["desktops.DELL (1)"])
        XCTAssertEqual(items[0].title, "DELL (1) is 2 desktops short")
        XCTAssertEqual(items[0].fix, .addDesktops)
    }

    func testNoFloatingWithoutAFreeDesktopOffersToAddOne() {
        var facts = facts(free: false)
        XCTAssertEqual(attentionItems(facts), [])
        facts.config.noFloating = true
        let items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["noFreeDesktop"])
        XCTAssertEqual(items[0].fix, .addFreeDesktop(deskID))
    }

    func testTakenShortcutsAndAHyperKeyThatIsNotInPlace() {
        var facts = facts()
        facts.takenShortcuts = ["⌃⌥⌘K", "⌃⌥⌘1"]
        facts.config.hyperKey = true
        var items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["shortcuts", "hyper"])
        XCTAssertEqual(items[0].title, "2 shortcuts are taken by another app")
        XCTAssertTrue(items[0].detail.hasPrefix("⌃⌥⌘K, ⌃⌥⌘1 do nothing"))
        facts.hyperOn = true
        facts.takenShortcuts = ["⌃⌥⌘K"]
        items = attentionItems(facts)
        XCTAssertEqual(items.map(\.title), ["A shortcut is taken by another app"])
    }

    func testAnAppThatIsNotInstalledIsANoteOnceWithItsFirstSlot() {
        var facts = facts()
        facts.config.configurations[0].displays[0].spaces.append(SpaceSpec(label: "Again", layout: Layout(slots: [slot("main", "brave")])))
        facts.desktopCounts[laptop] = 2
        facts.missingApps = ["brave", "elsewhere"]
        let items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["app.brave"])
        XCTAssertEqual(items[0].level, .note)
        XCTAssertEqual(items[0].fix, .showDesktop(configuration: deskID, display: laptop, desktop: 1, slot: "main"))
    }

    func testAMacOSWithoutTheMoveIsSaidAsSuchNotAsRefusedMoves() {
        var facts = facts()
        facts.moverAvailable = false
        var items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["mover"])
        XCTAssertTrue(items[0].detail.contains("refused the last moves"))
        XCTAssertTrue(items[0].detail.contains("Re-apply the layouts tries again"))
        facts.moverMissing = true
        items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["mover"])
        XCTAssertEqual(items[0].level, .warning)
        XCTAssertTrue(items[0].detail.contains("not on this Mac"))
        XCTAssertFalse(items[0].detail.contains("Re-apply"))
    }

    func testTheMostSeriousComesFirst() {
        var facts = facts()
        facts.waitingDrawerWindows = 2
        facts.sessionLocked = true
        facts.moverAvailable = false
        facts.spacesSpanDisplays = true
        facts.spacesOrderWarning = SpacesOrder.message
        let items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["spansDisplays", "mover", "spacesOrder", "drawerWaiting"])
        XCTAssertEqual(items.map(\.level), [.blocking, .warning, .warning, .note])
        XCTAssertTrue(items[3].detail.contains("when you unlock"))
    }
}
