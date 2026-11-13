import XCTest
@testable import FremspaceCore

final class ShareTests: XCTestCase {
    private let laptop = DisplayIdentity(vendor: 1, model: 11, serial: 4242, name: "Built-in Panel")
    private let big = DisplayIdentity(vendor: 2, model: 22, serial: 5151, name: "ACME 4K (1)")
    private let side = DisplayIdentity(vendor: 3, model: 33, serial: 6161, name: "ACME Strip")

    private func slot(_ id: String, _ x: Double, _ rule: Rule, focusable: Bool = false) -> Slot {
        Slot(id: id, rect: UnitRect(x: x, y: 0, w: 0.5, h: 1), rule: rule, focusable: focusable)
    }

    /// A desk: a laptop with one free desktop, a big display named "Main" with a layout and a
    /// drawer, a display that is ignored, and a scene across the first two.
    private var desk: Configuration {
        var web = slot("web", 0.5, Rule(bundleID: "com.example.browser", profile: "Work"))
        web.rules.append(Rule(bundleID: "com.example.browser", profile: "Home"))
        let code = SpaceSpec(label: "Code", layout: Layout(slots: [
            slot("ide", 0, Rule(bundleID: "com.example.ide", titleContains: "Inbox"), focusable: true), web,
        ]))
        let drawer = DrawerSpec(edge: .left, size: 0.3, layout: DrawerLayout(slots: [
            DrawerSlot(id: "top", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rules: [Rule(bundleID: "com.example.notes")]),
        ]))
        var scene = Scene(id: UUID(), name: "Deep work", desktops: [
            ConfiguredDesktop(display: big, index: 1), ConfiguredDesktop(display: side, index: 0),
        ], apps: ["com.example.music"])
        scene.setFocus("ide", on: big)
        scene.setDrawer(true, edge: .left, on: big)
        return Configuration(id: UUID(), name: "Home desk", displays: [
            DisplaySpec(identity: laptop, spaces: [SpaceSpec(label: "Rest")]),
            DisplaySpec(identity: big, spaces: [SpaceSpec(label: "Rest"), code], drawers: [drawer], label: "Main"),
            DisplaySpec(identity: side, ignored: true, spaces: [SpaceSpec(label: "Strip")]),
        ], scenes: [scene])
    }

    func testAnExportSaysNothingOfTheDisplaysNorOfTheFiltersUnlessAsked() throws {
        let export = sharedLayout(of: desk, withFilters: false)
        let text = String(decoding: try export.layout.data(), as: UTF8.self)
        for hidden in ["4242", "5151", "6161", "ACME", "Built-in", "serial", "vendor", "Work", "Home\"", "Inbox", "Strip"] {
            XCTAssertFalse(text.contains(hidden), "the file holds \(hidden)")
        }
        XCTAssertEqual(export.layout.displays.map(\.name), ["Display 1", "Main"])
        XCTAssertEqual(export.layout.name, "Home desk")
        XCTAssertEqual(export.report.displays, 2)
        XCTAssertEqual(export.report.displaysIgnored, 1)
        XCTAssertEqual(export.report.desktops, 3)
        XCTAssertEqual(export.report.slots, 2)
        XCTAssertEqual(export.report.drawers, 1)
        XCTAssertEqual(export.report.scenes, 1)
        XCTAssertEqual(export.report.profilesLeftOut, 2)
        XCTAssertEqual(export.report.titleFiltersLeftOut, 1)
        XCTAssertEqual(export.report.apps, ["com.example.browser", "com.example.ide", "com.example.music", "com.example.notes"])
        // Two rules that differed by their profile only are one.
        XCTAssertEqual(export.layout.displays[1].desktops[1].layout?.slots[1].rules, [Rule(bundleID: "com.example.browser")])

        let full = sharedLayout(of: desk, withFilters: true)
        XCTAssertEqual(full.report.profilesLeftOut, 0)
        XCTAssertEqual(full.layout.displays[1].desktops[1].layout?.slots[1].rules.map(\.profile), ["Work", "Home"])
        XCTAssertEqual(full.layout.displays[1].desktops[1].layout?.slots[0].rule.titleContains, "Inbox")
    }

    func testTheScenesOfAnExportNameTheDisplaysByPosition() {
        let scene = sharedLayout(of: desk, withFilters: false).layout.scenes[0]
        // The ignored display is not in the file: its part of the scene goes with it.
        XCTAssertEqual(scene.desktops, [SharedScene.Desktop(display: 1, index: 1)])
        XCTAssertEqual(scene.focus, [SharedScene.Focus(display: 1, slotID: "ide")])
        XCTAssertEqual(scene.drawers, [SharedScene.Drawer(display: 1, edge: .left, open: true)])
        XCTAssertEqual(scene.apps, ["com.example.music"])
    }

    func testAFileIsReadBackAsItWasWritten() throws {
        let layout = sharedLayout(of: desk, withFilters: true).layout
        let back = try SharedLayout.read(try layout.data())
        XCTAssertEqual(back, layout)
        XCTAssertEqual(shareFileName("Home desk"), "Home desk.fremspace-layout.json")
        XCTAssertEqual(shareFileName("../a:b/c"), "abc.fremspace-layout.json")
        XCTAssertEqual(shareFileName("///"), "Fremspace.fremspace-layout.json")
    }

    private func refused(_ change: (inout SharedLayout) -> Void) -> ShareError? {
        var layout = sharedLayout(of: desk, withFilters: false).layout
        change(&layout)
        guard let data = try? layout.data() else { return nil }
        do {
            _ = try SharedLayout.read(data)
            return nil
        } catch {
            return error as? ShareError
        }
    }

    func testAnotherKindOfFileOrANewerOneIsRefused() {
        XCTAssertEqual(refused { $0.kind = "something-else" }, .notALayout)
        XCTAssertEqual(refused { $0.version = 2 }, .newer(version: 2))
        XCTAssertEqual(refused { $0.version = 0 }, .notALayout)
        XCTAssertThrowsError(try SharedLayout.read(Data("{\"configurations\": []}".utf8)))
        XCTAssertThrowsError(try SharedLayout.read(Data(repeating: 32, count: SharedLayout.Limit.bytes + 1)))
        XCTAssertNil(refused { _ in })
    }

    func testAFileWithSomethingThatCannotBeIsRefused() {
        XCTAssertEqual(refused { $0.displays = [] }, .invalid("the number of displays"))
        XCTAssertEqual(refused { $0.displays[1].desktops[1].layout?.slots[0].rect.w = 3 }, .invalid("a slot's rectangle"))
        XCTAssertEqual(refused { $0.displays[1].desktops[1].layout?.slots[0].rect.x = -0.5 }, .invalid("a slot's rectangle"))
        XCTAssertEqual(refused { $0.displays[1].desktops[1].layout?.slots[1].id = "ide" }, .invalid("a slot's identifier"))
        XCTAssertEqual(refused { $0.displays[1].desktops[1].layout?.slots[0].id = "a b/../c" }, .invalid("a slot's identifier"))
        XCTAssertEqual(refused { $0.displays[1].desktops[1].layout?.slots[0].rules[0].bundleID = "rm -rf /" }, .invalid("an app's identifier"))
        XCTAssertEqual(refused { $0.displays[1].drawers[0].size = 4 }, .invalid("a drawer's size"))
        XCTAssertEqual(refused { $0.displays[1].desktops = Array(repeating: SpaceSpec(label: "x"), count: 40) }, .invalid("the number of desktops"))
    }

    func testAFileWithTheCallOptionOfOneDayStillSavesAfterItIsAdded() throws {
        let exported = String(decoding: try sharedLayout(of: desk, withFilters: false).layout.data(), as: UTF8.self)
        let old = exported.replacingOccurrences(of: "\"id\" : \"ide\"", with: "\"fullScreenCalls\" : true, \"id\" : \"ide\"")
        XCTAssertTrue(old.contains("fullScreenCalls"))
        let shared = try SharedLayout.read(Data(old.utf8))
        XCTAssertEqual(shared.displays[1].desktops[1].layout?.slots[0].fullScreenCalls, false)
        // Added and saved, the configuration reads back as it is in memory: the next Save compares
        // the two.
        let mine = DisplayIdentity(vendor: 9, model: 1, serial: 1, name: "Mine")
        let other = DisplayIdentity(vendor: 9, model: 2, serial: 2, name: "Other")
        let target = Configuration(id: UUID(), name: "Office", displays: [
            DisplaySpec(identity: mine, spaces: [SpaceSpec(label: "One")]),
            DisplaySpec(identity: other, spaces: [SpaceSpec(label: "A")]),
        ])
        let config = Config(configurations: [adding(shared, to: target, onto: [0: mine, 1: other]).configuration])
        let saved = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(saved, config)
    }

    func testNamesAreCutToOneLineAndAScenePartThatPointsNowhereIsDropped() throws {
        var layout = sharedLayout(of: desk, withFilters: false).layout
        layout.name = "A\nB" + String(repeating: "x", count: 200)
        layout.displays[0].name = "   "
        layout.scenes[0].desktops.append(SharedScene.Desktop(display: 7, index: 0))
        layout.scenes[0].focus = [SharedScene.Focus(display: 1, slotID: "nowhere")]
        layout.scenes[0].drawers.append(SharedScene.Drawer(display: 0, edge: .right, open: true))
        layout.scenes[0].apps.append("not an app")
        let back = try SharedLayout.read(try layout.data())
        XCTAssertEqual(back.name.count, SharedLayout.Limit.text)
        XCTAssertFalse(back.name.contains("\n"))
        XCTAssertEqual(back.displays[0].name, "Display 1")
        XCTAssertEqual(back.scenes[0].desktops, [SharedScene.Desktop(display: 1, index: 1)])
        XCTAssertEqual(back.scenes[0].focus, [])
        XCTAssertEqual(back.scenes[0].drawers, [SharedScene.Drawer(display: 1, edge: .left, open: true)])
        XCTAssertEqual(back.scenes[0].apps, ["com.example.music"])
    }

    func testAnImportAddsTheDesktopsAfterTheOwnersAndTheScenesFollow() {
        let shared = sharedLayout(of: desk, withFilters: false).layout
        // Another desk: two displays, the second with two desktops and a left drawer already.
        let mine = DisplayIdentity(vendor: 9, model: 1, serial: 1, name: "Mine")
        let other = DisplayIdentity(vendor: 9, model: 2, serial: 2, name: "Other")
        let own = DrawerSpec(edge: .left, size: 0.2, layout: DrawerLayout(slots: []))
        let target = Configuration(id: UUID(), name: "Office", displays: [
            DisplaySpec(identity: mine, spaces: [SpaceSpec(label: "One")]),
            DisplaySpec(identity: other, spaces: [SpaceSpec(label: "A"), SpaceSpec(label: "B")], drawers: [own]),
        ])
        XCTAssertEqual(defaultShareMapping(shared, onto: [mine, other]), [0: mine, 1: other])
        let result = adding(shared, to: target, onto: [0: mine, 1: other])
        XCTAssertEqual(result.configuration.displays[0].spaces.map(\.label), ["One", "Rest"])
        XCTAssertEqual(result.configuration.displays[1].spaces.map(\.label), ["A", "B", "Rest", "Code"])
        // The owner's drawer stays; the file's is on the same edge.
        XCTAssertEqual(result.configuration.displays[1].drawers, [own])
        XCTAssertEqual(result.report.desktops, 3)
        XCTAssertEqual(result.report.drawers, 0)
        XCTAssertEqual(result.report.drawersKept, 1)
        XCTAssertEqual(result.report.scenes, 1)
        XCTAssertEqual(result.report.displaysLeftOut, 0)
        let scene = result.configuration.scenes[0]
        // Desktop 2 of the file's second display is now the fourth of that display.
        XCTAssertEqual(scene.desktops, [ConfiguredDesktop(display: other, index: 3)])
        XCTAssertEqual(scene.focus(on: other), "ide")
        XCTAssertEqual(scene.drawer(.left, on: other), true)
        XCTAssertEqual(scene.apps, ["com.example.music"])
        XCTAssertEqual(target.displays[1].spaces.count, 2)
    }

    func testADisplayOfTheFileLeftOutTakesItsPartOfTheScenes() {
        let shared = sharedLayout(of: desk, withFilters: false).layout
        let mine = DisplayIdentity(vendor: 9, model: 1, serial: 1, name: "Mine")
        let target = Configuration(id: UUID(), name: "Laptop", displays: [DisplaySpec(identity: mine, spaces: [SpaceSpec(label: "One")])])
        // Only the file's first display is given a display: the scene is about the second.
        let result = adding(shared, to: target, onto: [0: mine])
        XCTAssertEqual(result.configuration.displays[0].spaces.map(\.label), ["One", "Rest"])
        XCTAssertEqual(result.report.displaysLeftOut, 1)
        XCTAssertEqual(result.report.scenes, 0)
        XCTAssertEqual(result.configuration.scenes, [])
        // Two displays of the file cannot go to one display here: the second is left out.
        let twice = adding(shared, to: target, onto: [0: mine, 1: mine])
        XCTAssertEqual(twice.report.displaysLeftOut, 1)
        XCTAssertEqual(twice.configuration.displays[0].spaces.count, 2)
    }
}
