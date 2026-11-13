import XCTest
@testable import FremspaceCore

final class DrawerModelTests: XCTestCase {
    private let identity = #"{"vendor":1,"model":2,"serial":3,"name":"Right"}"#
    private let right = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "Right")
    private let one = DrawerLayout(slots: [DrawerSlot(id: "all", rect: UnitRect(x: 0, y: 0, w: 1, h: 1))])

    private func drawerJSON(_ edge: String, size: Double = 0.375) -> String {
        #"{"edge":"\#(edge)","size":\#(size),"layout":{"slots":[{"id":"all","rect":{"x":0,"y":0,"w":1,"h":1}}]}}"#
    }

    private func display(_ json: String) throws -> DisplaySpec {
        try JSONDecoder().decode(DisplaySpec.self, from: Data(json.utf8))
    }

    func testDesktopWithoutDrawerStillDecodes() throws {
        let spec = try display(#"{"identity":\#(identity),"spaces":[{"label":"Code","unmatched":{"float":{}}}]}"#)
        XCTAssertEqual(spec.drawers, [])
        XCTAssertEqual(spec.spaces.map(\.label), ["Code"])
    }

    func testSingleDrawerOfTheFirstFormatStillDecodes() throws {
        let spec = try display(#"{"identity":\#(identity),"spaces":[{"label":"Code","drawer":\#(drawerJSON("left"))}]}"#)
        XCTAssertEqual(spec.drawers.map(\.edge), [.left])
    }

    func testDrawersOfTheDesktopsBecomeThoseOfTheDisplay() throws {
        // Code has a left drawer, Web a left (another size) and a right one: the display keeps the
        // first of each edge.
        let spec = try display(#"""
        {"identity":\#(identity),"spaces":[
          {"label":"Code","drawers":[\#(drawerJSON("left", size: 0.3))]},
          {"label":"Web","drawers":[\#(drawerJSON("left", size: 0.5)),\#(drawerJSON("right", size: 0.25))]},
          {"label":"Le reste"}]}
        """#)
        XCTAssertEqual(spec.drawers.map(\.edge), [.left, .right])
        XCTAssertEqual(spec.drawers.map(\.size), [0.3, 0.25])
    }

    func testDrawersOfTheDisplayWinOverThoseLeftOnDesktops() throws {
        // The owner removed the display's drawers: those an older file left on a desktop do not come back.
        let spec = try display(#"{"identity":\#(identity),"drawers":[],"spaces":[{"label":"Code","drawers":[\#(drawerJSON("left"))]}]}"#)
        XCTAssertEqual(spec.drawers, [])
    }

    func testOneDrawerPerEdge() {
        var spec = DisplaySpec(identity: right, spaces: [], drawers: [
            DrawerSpec(edge: .left, size: 0.3, layout: one),
            DrawerSpec(edge: .right, size: 0.3, layout: one),
            DrawerSpec(edge: .left, size: 0.5, layout: one),
        ])
        XCTAssertEqual(spec.drawers.map(\.edge), [.left, .right])
        XCTAssertEqual(spec.drawers.first?.size, 0.3)
        spec.drawers.append(DrawerSpec(edge: .right, size: 0.5, layout: one))
        XCTAssertEqual(spec.drawers.map(\.size), [0.3, 0.3])
    }

    func testDrawerSlotAppsRoundTripAndOlderSlotsHaveNone() throws {
        let old = try JSONDecoder().decode(DrawerSlot.self, from: Data(#"{"id":"top","rect":{"x":0,"y":0,"w":1,"h":1}}"#.utf8))
        XCTAssertEqual(old.rules, [])
        let written = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(written.contains("rules"))
        let slot = DrawerSlot(id: "top", rect: UnitRect(x: 0, y: 0, w: 1, h: 1),
                              rules: [Rule(bundleID: "com.apple.mail"), Rule(bundleID: "com.brave.Browser", profile: "Perso")])
        let back = try JSONDecoder().decode(DrawerSlot.self, from: try JSONEncoder().encode(slot))
        XCTAssertEqual(back, slot)
    }

    func testWindowsGoToTheDrawerSlotOfTheirApp() {
        func window(_ app: String, profile: String? = nil, standard: Bool = true) -> WindowInfo {
            WindowInfo(id: 1, pid: 1, bundleID: app, title: "w", profile: profile, isStandard: standard, isMinimized: false,
                       isFullScreen: false)
        }
        let half = UnitRect(x: 0, y: 0, w: 1, h: 0.5)
        let drawers = [
            DrawerSpec(edge: .left, size: 0.3, layout: DrawerLayout(slots: [
                DrawerSlot(id: "top", rect: half),
                DrawerSlot(id: "bottom", rect: half, rules: [Rule(bundleID: "com.apple.mail")])])),
            DrawerSpec(edge: .right, size: 0.3, layout: DrawerLayout(slots: [
                DrawerSlot(id: "all", rect: half, rules: [Rule(bundleID: "com.brave.Browser", profile: "Perso"), Rule(bundleID: "com.apple.mail")])])),
        ]
        XCTAssertEqual(drawerSlotKey(for: window("com.apple.mail"), in: drawers), "left.bottom")
        XCTAssertEqual(drawerSlotKey(for: window("com.brave.Browser", profile: "Perso"), in: drawers), "right.all")
        XCTAssertNil(drawerSlotKey(for: window("com.brave.Browser", profile: "Work"), in: drawers))
        XCTAssertNil(drawerSlotKey(for: window("com.apple.finder"), in: drawers))
        // A dialog is not a window to park.
        XCTAssertNil(drawerSlotKey(for: window("com.apple.mail", standard: false), in: drawers))
        // Mail also has a slot in the layout of the desktop it is on: the layout keeps it.
        let layout = Layout(slots: [Slot(id: "mail", rect: half, rule: Rule(bundleID: "com.apple.mail"))])
        XCTAssertNil(drawerSlotKey(for: window("com.apple.mail"), in: drawers, layout: layout))
        XCTAssertEqual(drawerSlotKey(for: window("com.brave.Browser", profile: "Perso"), in: drawers, layout: layout), "right.all")
    }

    func testDrawerRoundTrips() throws {
        let drawer = DrawerSpec(edge: .left, size: 0.375, layout: DrawerLayout(slots: [
            DrawerSlot(id: "top", rect: UnitRect(x: 0, y: 0, w: 1, h: 0.5)),
            DrawerSlot(id: "bottom", rect: UnitRect(x: 0, y: 0.5, w: 1, h: 0.5)),
        ]))
        let spec = DisplaySpec(identity: right, spaces: [SpaceSpec(label: "Browse")], drawers: [drawer])
        let back = try JSONDecoder().decode(DisplaySpec.self, from: try JSONEncoder().encode(spec))
        XCTAssertEqual(back, spec)
        XCTAssertEqual(back.drawers, [drawer])
    }
}
