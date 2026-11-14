import XCTest
@testable import FremspaceCore

final class DesktopRoutingTests: XCTestCase {
    private let builtIn = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let left = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "DELL left")
    private let brave = "com.brave.Browser", slack = "com.tinyspeck.slackmacgap", mail = "com.apple.mail"
    private let teams = "com.microsoft.teams2", finder = "com.apple.finder", music = "com.apple.Music"

    private func layout(_ apps: [String], locked: Bool = true) -> Layout {
        Layout(slots: apps.enumerated().map { i, app in
            Slot(id: "s\(i)", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: app), locked: locked)
        })
    }

    /// Built-in: Music, Slack, Mail, Teams. Left DELL: Code (Brave, VS Code), Web (Brave, unlocked), Le reste (free).
    private var configuration: Configuration {
        Configuration(id: UUID(), name: "Home desk", displays: [
            DisplaySpec(identity: builtIn, spaces: [
                SpaceSpec(label: "Music", layout: layout([music])),
                SpaceSpec(label: "Slack", layout: layout([slack])),
                SpaceSpec(label: "Mail", layout: layout([mail])),
                SpaceSpec(label: "Teams", layout: layout([teams])),
            ]),
            DisplaySpec(identity: left, spaces: [
                SpaceSpec(label: "Code", layout: layout([brave, "com.microsoft.VSCode"])),
                SpaceSpec(label: "Web", layout: layout([brave], locked: false)),
                SpaceSpec(label: "Le reste"),
            ]),
        ])
    }

    private func d(_ display: DisplayIdentity, _ index: Int) -> ConfiguredDesktop {
        ConfiguredDesktop(display: display, index: index)
    }

    private var all: Set<ConfiguredDesktop> {
        [d(builtIn, 0), d(builtIn, 1), d(builtIn, 2), d(builtIn, 3), d(left, 0), d(left, 1), d(left, 2)]
    }

    private func window(_ app: String) -> WindowInfo {
        WindowInfo(id: 1, pid: 1, bundleID: app, title: "w", profile: nil, isStandard: true, isMinimized: false,
                   isFullScreen: false)
    }

    private func route(_ app: String, on here: ConfiguredDesktop?, _ reason: RouteReason, remembered: ConfiguredDesktop? = nil,
                       deliberate: Bool = true, byCommand: Bool = false, available: Set<ConfiguredDesktop>? = nil,
                       configuration custom: Configuration? = nil, strict: Bool = false,
                       floating: Set<String> = []) -> Route {
        FremspaceCore.route(window: window(app), on: here, reason: reason, configuration: custom ?? configuration,
                            remembered: remembered, rememberedDeliberately: deliberate, sentByCommand: byCommand,
                            noFloating: strict, floatingApps: floating, available: available ?? all)
    }

    func testWithoutASlotAWindowLeavesALayoutDesktopForAFreeOne() {
        // Finder has no slot anywhere: on "Code" it goes to "Le reste"; by default it floats.
        XCTAssertEqual(route(finder, on: d(left, 0), .appeared, strict: true), .send(d(left, 2)))
        XCTAssertEqual(route(finder, on: d(left, 0), .appeared), .stay)
        // From another display too, when its own has no free desktop.
        XCTAssertEqual(route(finder, on: d(builtIn, 1), .startup, strict: true), .send(d(left, 2)))
        // Already on a free desktop, or with a slot here: nothing moves.
        XCTAssertEqual(route(finder, on: d(left, 2), .reapply, strict: true), .stay)
        XCTAssertEqual(route(brave, on: d(left, 0), .reapply, strict: true), .stay)
    }

    func testNoFloatingDoesNotKeepARememberedWindowOnALayoutDesktop() {
        XCTAssertEqual(route(finder, on: d(left, 0), .reapply, remembered: d(left, 0), strict: true), .send(d(left, 2)))
        // Nor bring it back there at login.
        XCTAssertEqual(route(finder, on: d(left, 2), .login, remembered: d(left, 0), strict: true), .stay)
        // A command still puts a window on a layout desktop.
        XCTAssertEqual(route(finder, on: d(left, 0), .reapply, remembered: d(left, 0), byCommand: true, strict: true), .stay)
    }

    func testNoFloatingSendsAwayAWindowDroppedByHandOnALayoutDesktop() {
        // Finder dragged from "Le reste" onto "Code": it goes back to a free desktop at once.
        XCTAssertEqual(route(finder, on: d(left, 0), .handMoved(from: d(left, 2)), strict: true), .send(d(left, 2)))
        // By default a hand move is the owner's will.
        XCTAssertEqual(route(finder, on: d(left, 0), .handMoved(from: d(left, 2))), .stay)
        // Dropped on a free desktop, or on a desktop where it has a slot, or sent by a command: it stays.
        XCTAssertEqual(route(finder, on: d(left, 2), .handMoved(from: d(left, 0)), strict: true), .stay)
        XCTAssertEqual(route(brave, on: d(left, 0), .handMoved(from: d(left, 1)), strict: true), .stay)
        XCTAssertEqual(route(finder, on: d(left, 0), .handMoved(from: d(left, 2)), byCommand: true, strict: true), .stay)
    }

    func testNoFloatingAlsoMovesFixedSizeWindowsButNotDialogs() {
        var calculator = window("com.apple.calculator")
        calculator.isFixedSize = true
        func route(_ window: WindowInfo, strict: Bool) -> Route {
            FremspaceCore.route(window: window, on: d(left, 0), reason: .reapply, configuration: configuration,
                                remembered: nil, sentByCommand: false, noFloating: strict, available: all)
        }
        XCTAssertEqual(route(calculator, strict: true), .send(d(left, 2)))
        XCTAssertEqual(route(calculator, strict: false), .stay)
        var dialog = window("com.apple.calculator")
        dialog.isStandard = false
        XCTAssertEqual(route(dialog, strict: true), .stay)
        // A fixed-size window of an app of the layout (its settings) stays with it.
        var settings = window(brave)
        settings.isFixedSize = true
        XCTAssertEqual(route(settings, strict: true), .stay)
    }

    func testAnAppThatMayFloatStaysOnALayoutDesktop() {
        // Finder has no slot anywhere and the owner lets it float: on "Code" it stays, however it got there.
        XCTAssertEqual(route(finder, on: d(left, 0), .appeared, strict: true, floating: [finder]), .stay)
        XCTAssertEqual(route(finder, on: d(left, 0), .startup, strict: true, floating: [finder]), .stay)
        XCTAssertEqual(route(finder, on: d(left, 0), .reapply, remembered: d(left, 0), strict: true, floating: [finder]), .stay)
        XCTAssertEqual(route(finder, on: d(left, 0), .handMoved(from: d(left, 2)), strict: true, floating: [finder]), .stay)
        // At login it goes back to the layout desktop it floated on.
        XCTAssertEqual(route(finder, on: d(left, 2), .login, remembered: d(left, 0), strict: true, floating: [finder]),
                       .send(d(left, 0)))
        // The list names apps: another app without a slot still goes to the free desktop.
        XCTAssertEqual(route(teams, on: d(left, 0), .appeared, strict: true, floating: [finder]), .send(d(builtIn, 3)))
        XCTAssertEqual(route("com.apple.Notes", on: d(left, 0), .appeared, strict: true, floating: [finder]), .send(d(left, 2)))
        // A fixed-size window of such an app (Calculator) stays too.
        var calculator = window("com.apple.calculator")
        calculator.isFixedSize = true
        XCTAssertEqual(FremspaceCore.route(window: calculator, on: d(left, 0), reason: .appeared, configuration: configuration,
                                           remembered: nil, sentByCommand: false, noFloating: true,
                                           floatingApps: ["com.apple.calculator"], available: all), .stay)
    }

    func testAnAppThatMayFloatIsNotPulledToItsSlotOnAnotherDesktop() {
        // Slack has a slot on its own desktop. Opened on "Code" it goes there, unless it may float.
        XCTAssertEqual(route(slack, on: d(left, 0), .appeared), .send(d(builtIn, 1)))
        XCTAssertEqual(route(slack, on: d(left, 0), .appeared, floating: [slack]), .stay)
        XCTAssertEqual(route(slack, on: d(left, 0), .startup, remembered: d(builtIn, 1), deliberate: false, strict: true,
                             floating: [slack]), .stay)
        // On the desktop of its slot nothing changes, and login still takes it back to its place.
        XCTAssertEqual(route(slack, on: d(builtIn, 1), .appeared, floating: [slack]), .stay)
        XCTAssertEqual(route(slack, on: d(left, 0), .login, remembered: d(builtIn, 1), floating: [slack]), .send(d(builtIn, 1)))
        // A locked slot keeps its window: dragged away by hand, it goes back.
        XCTAssertEqual(route(slack, on: d(left, 0), .handMoved(from: d(builtIn, 1)), floating: [slack]), .send(d(builtIn, 1)))
        // Reopened by macOS on a display the configuration ignores, it goes to its slot like any other.
        XCTAssertEqual(FremspaceCore.route(window: window(slack), on: nil, reason: .startup, configuration: configuration,
                                           remembered: nil, sentByCommand: false, onIgnoredDisplay: true,
                                           floatingApps: [slack], available: all), .send(d(builtIn, 1)))
    }

    func testTheAppsThatMayFloatAreAGeneralSettingWrittenOnlyWhenUsed() throws {
        var config = Config(configurations: [configuration])
        let plain = try JSONEncoder().encode(config)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("floatingApps"))
        let older = try JSONDecoder().decode(Config.self, from: plain)
        XCTAssertEqual(older.floatingApps, [])
        config.floatingApps = [finder, "com.apple.calculator"]
        let decoded = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded.floatingApps, [finder, "com.apple.calculator"])
        // A file edited by hand: an app named twice is listed once, an empty name is dropped.
        let byHand = Data(#"{"version":1,"configurations":[],"floatingApps":["com.apple.finder","","com.apple.finder","com.apple.Notes"]}"#.utf8)
        let cleaned = try JSONDecoder().decode(Config.self, from: byHand)
        XCTAssertEqual(cleaned.floatingApps, [finder, "com.apple.Notes"])
    }

    func testFixedSizeWindowOfAnAppWithASlotGoesToThatAppsDesktop() {
        // A mail reminder opens on the desktop in front, "Code": it belongs with Mail, not on the free desktop.
        var reminder = window(mail)
        reminder.isFixedSize = true
        func route(on here: ConfiguredDesktop, strict: Bool = true, available: Set<ConfiguredDesktop>? = nil) -> Route {
            FremspaceCore.route(window: reminder, on: here, reason: .appeared, configuration: configuration,
                                remembered: nil, sentByCommand: false, noFloating: strict, available: available ?? all)
        }
        XCTAssertEqual(route(on: d(left, 0)), .send(d(builtIn, 2)))
        XCTAssertEqual(route(on: d(builtIn, 1)), .send(d(builtIn, 2)))
        // With its app, on a free desktop, or without "no floating windows": it stays.
        XCTAssertEqual(route(on: d(builtIn, 2)), .stay)
        XCTAssertEqual(route(on: d(left, 2)), .stay)
        XCTAssertEqual(route(on: d(left, 0), strict: false), .stay)
        // Its app's desktop is not there (the display is unplugged): a free desktop, as before.
        XCTAssertEqual(route(on: d(left, 0), available: [d(left, 0), d(left, 1), d(left, 2)]), .send(d(left, 2)))
        // An app with slots on several desktops: the one of the window's own display first.
        var panel = window(brave)
        panel.isFixedSize = true
        XCTAssertEqual(FremspaceCore.route(window: panel, on: d(builtIn, 0), reason: .appeared, configuration: configuration,
                                           remembered: nil, sentByCommand: false, noFloating: true, available: all),
                       .send(d(left, 0)))
    }

    func testNoFloatingKeepsEveryWindowOfAnAppOfTheLayout() {
        // Brave has slots for one profile on "Code": a window of a profile without a slot stays there.
        var custom = configuration
        custom.displays[1].spaces[0].layout?.slots[0].rules[0].profile = "Work"
        custom.displays[1].spaces[1].layout?.slots[0].rules[0].profile = "Work"
        var guest = window(brave)
        guest.profile = "Guest"
        XCTAssertEqual(FremspaceCore.route(window: guest, on: d(left, 0), reason: .reapply, configuration: custom,
                                           remembered: nil, sentByCommand: false, noFloating: true, available: all), .stay)
    }

    func testNoFloatingWithoutAFreeDesktopMovesNothing() {
        var noFree = configuration
        noFree.displays[1].spaces.removeLast()
        XCTAssertEqual(route(finder, on: d(left, 0), .appeared, available: all.subtracting([d(left, 2)]), configuration: noFree, strict: true), .stay)
    }

    func testNoFloatingIsAGeneralSettingAndOlderFilesHaveItOff() throws {
        let on = Config(configurations: [configuration], noFloating: true)
        let data = try JSONEncoder().encode(on)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertTrue(decoded.noFloating)
        let plain = try JSONEncoder().encode(Config(configurations: [configuration]))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("noFloating"))
        let older = try JSONDecoder().decode(Config.self, from: plain)
        XCTAssertFalse(older.noFloating)
        // Written in a configuration for one day: read as the general setting.
        let legacy = Data(#"{"version":1,"configurations":[{"id":"6F1C2D3E-4A5B-4C6D-8E7F-90A1B2C3D4E5","name":"Desk","displays":[],"noFloating":true}]}"#.utf8)
        let migrated = try JSONDecoder().decode(Config.self, from: legacy)
        XCTAssertTrue(migrated.noFloating)
    }

    func testSlackAppearingOnMailGoesToSlack() {
        XCTAssertEqual(route(slack, on: d(builtIn, 2), .appeared), .send(d(builtIn, 1)))
    }

    func testWindowOnFreeDesktopStays() {
        XCTAssertEqual(route(brave, on: d(left, 2), .appeared), .stay)
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply), .stay)
    }

    func testBraveOnWebStaysAlthoughItMatchesCodeToo() {
        XCTAssertEqual(route(brave, on: d(left, 1), .startup), .stay)
    }

    func testUnmatchedAppStays() {
        XCTAssertEqual(route(finder, on: d(builtIn, 2), .appeared), .stay)
    }

    func testHandMoveOfLockedWindowGoesBack() {
        XCTAssertEqual(route(teams, on: d(builtIn, 2), .handMoved(from: d(builtIn, 3))), .send(d(builtIn, 3)))
    }

    func testAHandMoveIsJudgedOnTheSlotTheWindowHeld() {
        // One app with a locked slot and an unlocked one on the same desktop, in both orders.
        func desk(lockedFirst: Bool) -> Configuration {
            let locked = Slot(id: "pinned", rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: brave), locked: true)
            let loose = Slot(id: "loose", rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 1), rule: Rule(bundleID: brave), locked: false)
            return Configuration(id: UUID(), name: "Desk", displays: [DisplaySpec(identity: left, spaces: [
                SpaceSpec(label: "Web", layout: Layout(slots: lockedFirst ? [locked, loose] : [loose, locked])),
                SpaceSpec(label: "Rest"),
            ])])
        }
        for lockedFirst in [true, false] {
            func moved(held: String?) -> Route {
                FremspaceCore.route(window: window(brave), on: d(left, 1), reason: .handMoved(from: d(left, 0)),
                                    configuration: desk(lockedFirst: lockedFirst), remembered: nil, heldSlot: held,
                                    sentByCommand: false, available: [d(left, 0), d(left, 1)])
            }
            XCTAssertEqual(moved(held: "pinned"), .send(d(left, 0)), "locked first: \(lockedFirst)")
            XCTAssertEqual(moved(held: "loose"), .stay, "locked first: \(lockedFirst)")
            // Not known (the window was never placed): the first slot that takes it, as before.
            XCTAssertEqual(moved(held: nil), lockedFirst ? .send(d(left, 0)) : .stay)
        }
    }

    func testHandMoveOfUnlockedWindowStays() {
        XCTAssertEqual(route(brave, on: d(left, 2), .handMoved(from: d(left, 1))), .stay)
    }

    func testCommandWinsOverLock() {
        // Teams sent to Mail with "Send to desktop": its lock does not pull it back, and no pass sends it away.
        XCTAssertEqual(route(teams, on: d(builtIn, 2), .handMoved(from: d(builtIn, 3)), remembered: d(builtIn, 2),
                             byCommand: true), .stay)
        XCTAssertEqual(route(teams, on: d(builtIn, 2), .reapply, remembered: d(builtIn, 2), byCommand: true), .stay)
    }

    func testMissingRememberedDesktopFallsBackOrStays() {
        // Remembered on Web, which is gone: Brave goes to the first desktop with a Brave slot.
        let withoutWeb = all.subtracting([d(left, 1)])
        XCTAssertEqual(route(brave, on: d(builtIn, 2), .appeared, remembered: d(left, 1), available: withoutWeb),
                       .send(d(left, 0)))
        // No desktop with a Slack slot is there: Slack stays where it is.
        let noSlack = all.subtracting([d(builtIn, 1)])
        XCTAssertEqual(route(slack, on: d(builtIn, 2), .appeared, remembered: d(builtIn, 1), available: noSlack), .stay)
        // At login, a remembered desktop that is gone is not a target either.
        XCTAssertEqual(route(finder, on: d(builtIn, 0), .login, remembered: d(left, 1), available: withoutWeb), .stay)
    }

    func testLoginRestoresFreeDesktopWindows() {
        XCTAssertEqual(route(finder, on: d(builtIn, 0), .login, remembered: d(left, 2)), .send(d(left, 2)))
        XCTAssertEqual(route(finder, on: d(left, 2), .login, remembered: d(left, 2)), .stay)
    }

    func testWindowOnAnIgnoredDisplayGoesToItsDesktop() {
        func ignored(_ app: String, _ reason: RouteReason, remembered: ConfiguredDesktop? = nil) -> Route {
            FremspaceCore.route(window: window(app), on: nil, reason: reason, configuration: configuration,
                                remembered: remembered, sentByCommand: false, onIgnoredDisplay: true, available: all)
        }
        // macOS reopened Mail on the ignored display: it goes to the desktop with its slot.
        XCTAssertEqual(ignored(mail, .startup), .send(d(builtIn, 2)))
        XCTAssertEqual(ignored(mail, .appeared), .send(d(builtIn, 2)))
        // Its remembered desktop comes first when it has a slot there.
        XCTAssertEqual(ignored(brave, .reapply, remembered: d(left, 1)), .send(d(left, 1)))
        // An app without a slot stays on the ignored display.
        XCTAssertEqual(ignored(finder, .startup), .stay)
        XCTAssertEqual(ignored(finder, .startup, remembered: d(left, 2)), .stay)
        // A display that is unknown rather than ignored still keeps its windows.
        XCTAssertEqual(route(mail, on: nil, .startup), .stay)
    }

    func testWindowThatNoLongerMatchesItsSlotLeaves() {
        // The owner gave Code's Brave slot the profile Work: a Brave window of another profile,
        // remembered in that slot, goes to Web (any profile) instead of staying on Code.
        var changed = configuration
        changed.displays[1].spaces[0].layout = Layout(slots: [
            Slot(id: "s0", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: brave, profile: "Work")),
        ])
        XCTAssertEqual(route(brave, on: d(left, 0), .reapply, remembered: d(left, 0), deliberate: false, configuration: changed),
                       .send(d(left, 1)))
        // A place the owner chose (Send to desktop) still holds.
        XCTAssertEqual(route(brave, on: d(left, 0), .reapply, remembered: d(left, 0), deliberate: true, configuration: changed),
                       .stay)
    }

    func testReapplyTakesBackAWindowItsAppPutOnTheFreeDesktop() {
        // Brave showed its window again on "Le reste"; its remembered place is a slot of "Web".
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply, remembered: d(left, 1), deliberate: false), .send(d(left, 1)))
        // The owner dragged it to "Le reste": that is where it is remembered, it stays.
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply, remembered: d(left, 2)), .stay)
        // Remembered elsewhere outside any slot (a command, a hand move): not taken back either.
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply, remembered: d(left, 1)), .stay)
        // A window Fremspace never remembered, one a command sent, an app that may float: they stay.
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply), .stay)
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply, remembered: d(left, 1), deliberate: false, byCommand: true), .stay)
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply, remembered: d(left, 1), deliberate: false, floating: [brave]), .stay)
        // Its remembered desktop is not there (a display unplugged), or gives it no slot any more.
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply, remembered: d(left, 1), deliberate: false,
                             available: [d(left, 0), d(left, 2)]), .stay)
        XCTAssertEqual(route(brave, on: d(left, 2), .reapply, remembered: d(builtIn, 1), deliberate: false), .stay)
        // Only ⌃⌥⌘R: a start of Fremspace and a new window leave the free desktop alone.
        XCTAssertEqual(route(brave, on: d(left, 2), .startup, remembered: d(left, 1), deliberate: false), .stay)
        XCTAssertEqual(route(brave, on: d(left, 2), .appeared, remembered: d(left, 1), deliberate: false), .stay)
    }

    func testAWindowOnTheFreeDesktopGoesToTheSlotItsAppWasJustGiven() {
        func given(_ app: String, on here: ConfiguredDesktop?, remembered: ConfiguredDesktop? = nil, byCommand: Bool = false,
                   floating: Set<String> = []) -> Route {
            FremspaceCore.route(window: window(app), on: here, reason: .reapply, configuration: configuration,
                                remembered: remembered, sentByCommand: byCommand, noFloating: true, floatingApps: floating,
                                givenASlot: true, available: all)
        }
        // Slack sat on "Le reste", sent there while it had no slot; the save gives it one.
        XCTAssertEqual(given(slack, on: d(left, 2), remembered: d(left, 2)), .send(d(builtIn, 1)))
        // Without that save, the free desktop keeps it, as it keeps everything.
        XCTAssertEqual(route(slack, on: d(left, 2), .reapply, remembered: d(left, 2), strict: true), .stay)
        // What a command put on the free desktop stays, and so does an app that may float.
        XCTAssertEqual(given(slack, on: d(left, 2), remembered: d(left, 2), byCommand: true), .stay)
        XCTAssertEqual(given(slack, on: d(left, 2), floating: [slack]), .stay)
        // On a desktop with a layout nothing changes: already in its slot, it stays.
        XCTAssertEqual(given(slack, on: d(builtIn, 1)), .stay)
    }
}
