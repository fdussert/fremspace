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
}
