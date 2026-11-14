import XCTest
@testable import FremspaceCore

final class AskedWindowsTests: XCTestCase {
    private let finder = "com.example.files"
    private let start = Date(timeIntervalSince1970: 1_000)

    func testTheNextNewWindowOfTheAppIsTheOneAskedForAndOnlyThatOne() {
        var asked = AskedWindows()
        asked.expect(finder, existing: [10, 11], now: start)
        // A window the app already had is looked at first: not the one.
        XCTAssertFalse(asked.take(10, bundleID: finder, now: start.addingTimeInterval(1)))
        XCTAssertFalse(asked.take(20, bundleID: "com.example.other", now: start.addingTimeInterval(1)))
        XCTAssertTrue(asked.take(12, bundleID: finder, now: start.addingTimeInterval(1.5)))
        // The window the owner opens next is an ordinary one.
        XCTAssertFalse(asked.take(13, bundleID: finder, now: start.addingTimeInterval(2)))
    }

    func testARequestThatGotNoWindowInTimeIsForgotten() {
        var asked = AskedWindows()
        asked.expect(finder, existing: [], now: start)
        XCTAssertFalse(asked.take(12, bundleID: finder, now: start.addingTimeInterval(AskedWindows.wait + 1)))
        XCTAssertFalse(asked.take(13, bundleID: finder, now: start.addingTimeInterval(1)))
    }

    func testNothingAskedNothingTaken() {
        var asked = AskedWindows()
        XCTAssertFalse(asked.take(12, bundleID: finder, now: start))
    }

    func testAWindowShowsAFolderByItsDocumentAddressElseByItsTitleInTheFinder() {
        let folder = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Example/Layouts", isDirectory: true)
        XCTAssertTrue(windowShows(folder, document: "file:///Users/someone/Library/Application%20Support/Example/Layouts/", title: nil, byTitle: false))
        // Another folder of the same name: its address says it is not the one, whatever its title.
        XCTAssertFalse(windowShows(folder, document: "file:///Users/someone/Other/Layouts/", title: "Layouts", byTitle: true))
        XCTAssertTrue(windowShows(folder, document: nil, title: "Layouts", byTitle: true))
        XCTAssertFalse(windowShows(folder, document: nil, title: "Layouts", byTitle: false))
        XCTAssertFalse(windowShows(folder, document: nil, title: "Downloads", byTitle: true))
    }

    func testTheFoldersTheSlotsAskFor() throws {
        let laptop = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
        let side = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "Side")
        func slot(_ id: String, _ app: String, folder: String?) -> Slot {
            var rule = Rule(bundleID: app)
            rule.folder = folder
            return Slot(id: id, rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: rule)
        }
        var ignored = DisplaySpec(identity: side, spaces: [SpaceSpec(label: "Side", layout: Layout(slots: [slot("s", finder, folder: "~/Side")]))])
        ignored.ignored = true
        let configuration = Configuration(id: UUID(), name: "Desk", displays: [
            DisplaySpec(identity: laptop, spaces: [
                SpaceSpec(label: "Work", layout: Layout(slots: [slot("files", finder, folder: "~/Projects"), slot("web", "com.example.web", folder: nil)])),
                SpaceSpec(label: "Free"),
                // The same folder again, a folder that is only spaces, and another one.
                SpaceSpec(label: "More", layout: Layout(slots: [slot("again", finder, folder: "~/Projects"), slot("blank", finder, folder: "  "),
                                                               slot("inbox", finder, folder: "~/Inbox")])),
            ]),
            ignored,
        ])
        XCTAssertEqual(foldersToOpen(configuration), [
            FolderToOpen(folder: "~/Projects", bundleID: finder, desktop: ConfiguredDesktop(display: laptop, index: 0), slotID: "files"),
            FolderToOpen(folder: "~/Inbox", bundleID: finder, desktop: ConfiguredDesktop(display: laptop, index: 2), slotID: "inbox"),
        ])
        // Kept in the configuration file, and absent from the files written before it existed.
        let data = try JSONEncoder().encode(configuration)
        let back = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(back.displays[0].spaces[0].layout?.slots[0].rule.folder, "~/Projects")
        XCTAssertNil(back.displays[0].spaces[0].layout?.slots[1].rule.folder)
        let old = try JSONDecoder().decode(Rule.self, from: Data(#"{"bundleID":"com.example.files"}"#.utf8))
        XCTAssertNil(old.folder)
    }
}
