import XCTest
import CoreGraphics
@testable import FremspaceCore

final class CaptureTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 3360, height: 1890)

    private func window(_ id: UInt32, _ bundle: String, minimized: Bool = false, fullScreen: Bool = false) -> WindowInfo {
        WindowInfo(id: id, pid: 1, bundleID: bundle, title: "", profile: nil, isStandard: true,
                   isMinimized: minimized, isFullScreen: fullScreen)
    }

    func testCaptureRoundsToCleanFractions() {
        let layout = capture(windows: [
            (window(1, "com.microsoft.VSCode"), CGRect(x: 8, y: 8, width: 2004, height: 1874)),
            (window(2, "com.brave.Browser"), CGRect(x: 2020, y: 8, width: 1332, height: 1874)),
        ], visible: visible)
        XCTAssertEqual(layout.slots.map(\.rect), [UnitRect(x: 0, y: 0, w: 0.6, h: 1), UnitRect(x: 0.6, y: 0, w: 0.4, h: 1)])
        XCTAssertEqual(layout.slots.map(\.rule.bundleID), ["com.microsoft.VSCode", "com.brave.Browser"])
        XCTAssertEqual(layout.slots.map(\.id), ["vscode", "browser"])
    }

    func testCaptureStacksSameAppSameRect() {
        let frame = CGRect(x: 8, y: 8, width: 3344, height: 1874)
        let layout = capture(windows: [(window(1, "com.brave.Browser"), frame), (window(2, "com.brave.Browser"), frame)], visible: visible)
        XCTAssertEqual(layout.slots.count, 1)
    }

    func testCaptureSkipsUnmanageableAndNeverOverlaps() {
        let layout = capture(windows: [
            (window(1, "com.apple.finder", minimized: true), CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            (window(2, "com.apple.Safari", fullScreen: true), visible),
            (window(3, "com.microsoft.VSCode"), CGRect(x: 8, y: 8, width: 2004, height: 1874)),
            (window(4, "com.sublimetext.4"), CGRect(x: 1000, y: 8, width: 2352, height: 1874)),
        ], visible: visible)
        XCTAssertEqual(layout.slots.map(\.rule.bundleID), ["com.microsoft.VSCode"])
    }
}
