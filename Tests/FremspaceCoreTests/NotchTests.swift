import XCTest
@testable import FremspaceCore

final class NotchTests: XCTestCase {
    private let laptop = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let big = DisplayIdentity(vendor: 2, model: 1, serial: 1, name: "DELL (1)")
    /// A 14" MacBook Pro: the notch is 185 wide and 32 high in the middle of the top.
    private let macbook = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32, left: 663.5, right: 663.5)
    private let dell = NotchGeometry(screen: CGRect(x: 1512, y: -319, width: 3360, height: 1890), safeTop: 0, left: nil, right: nil)

    func testOnlyADisplayWhoseDesktopChangedIsNamed() {
        XCTAssertEqual(changedDesktops(from: [laptop: 0, big: 1], to: [laptop: 0, big: 2]), [big])
        XCTAssertEqual(changedDesktops(from: [laptop: 0, big: 1], to: [laptop: 1, big: 0]), [laptop, big])
        XCTAssertEqual(changedDesktops(from: [laptop: 0, big: 1], to: [laptop: 0, big: 1]), [])
    }

    func testADisplayThatWasNotThereBeforeSaysNothing() {
        // Just connected, or back from a full-screen Space.
        XCTAssertEqual(changedDesktops(from: [laptop: 0], to: [laptop: 0, big: 2]), [])
        XCTAssertEqual(changedDesktops(from: [laptop: 0, big: 2], to: [laptop: 0]), [])
    }

    func testTheBannerNamesTheDesktopOrNumbersIt() {
        XCTAssertEqual(desktopBanner(label: "Mail", index: 2, count: 4), DesktopBanner(label: "Mail", count: 4, index: 2))
        XCTAssertEqual(desktopBanner(label: nil, index: 4, count: 5).label, "Desktop 5")
        XCTAssertEqual(desktopBanner(label: "  ", index: 0, count: 1).label, "Desktop 1")
        // A count read before macOS added the desktop never leaves the shown one out.
        XCTAssertEqual(desktopBanner(label: nil, index: 3, count: 2).count, 4)
    }

    func testTheNotchIsBetweenTheTwoSidesOfTheMenuBar() {
        XCTAssertEqual(macbook.notch, CGRect(x: 663.5, y: 950, width: 185, height: 32))
        XCTAssertNil(dell.notch)
        XCTAssertTrue(macbook.isOnNotch(CGPoint(x: 756, y: 970)))
        XCTAssertTrue(macbook.isOnNotch(CGPoint(x: 756, y: 949)))
        XCTAssertFalse(macbook.isOnNotch(CGPoint(x: 600, y: 970)))
        XCTAssertFalse(dell.isOnNotch(CGPoint(x: 3000, y: 1560)))
    }

    func testWhatHangsFromTheNotchStartsAtTheTopAndShowsItsContentUnderIt() {
        // Narrower than the notch: as wide as the notch.
        XCTAssertEqual(macbook.hanging(content: CGSize(width: 120, height: 30)), CGRect(x: 663.5, y: 920, width: 185, height: 62))
        // Wider: centred on the notch.
        XCTAssertEqual(macbook.hanging(content: CGSize(width: 560, height: 240)), CGRect(x: 476, y: 710, width: 560, height: 272))
    }

    func testWithoutANotchItIsCentredUnderTheMenuBar() {
        let frame = dell.hanging(content: CGSize(width: 200, height: 40))
        XCTAssertEqual(frame, CGRect(x: 1512 + 1580, y: 1571 - 24 - 6 - 40, width: 200, height: 40))
    }

    func testTheMapTakesItsKeysOnlyWhileThePointerIsOnIt() {
        let panel = macbook.hanging(content: CGSize(width: 560, height: 240))
        // On the map, under the notch: the arrows are the map's.
        XCTAssertEqual(macbook.mapKeys(pointer: CGPoint(x: 756, y: 820), panel: panel), .map)
        XCTAssertEqual(macbook.mapKeys(pointer: CGPoint(x: 500, y: 930), panel: panel), .map)
        // Resting on the notch, where it opened the map: the keys are still the app's.
        XCTAssertEqual(macbook.mapKeys(pointer: CGPoint(x: 756, y: 970), panel: panel), .app)
        // Gone: the map closes.
        XCTAssertEqual(macbook.mapKeys(pointer: CGPoint(x: 200, y: 400), panel: panel), .close)
    }

    func testItStaysInsideTheScreen() {
        let narrow = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 400, height: 300), safeTop: 0, left: nil, right: nil)
        XCTAssertEqual(narrow.hanging(content: CGSize(width: 600, height: 40)).minX, 0)
        XCTAssertEqual(narrow.hanging(content: CGSize(width: 600, height: 40)).width, 400)
    }

    func testTheTwoSettingsAreOnUnlessSwitchedOffAndOnlyThenWritten() throws {
        var config = Config(configurations: [])
        XCTAssertTrue(config.desktopNames)
        XCTAssertTrue(config.notchMap)
        let plain = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(plain.contains("desktopNames"))
        XCTAssertFalse(plain.contains("notchMap"))
        config.desktopNames = false
        config.notchMap = false
        let back = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(config))
        XCTAssertFalse(back.desktopNames)
        XCTAssertFalse(back.notchMap)
    }
}
