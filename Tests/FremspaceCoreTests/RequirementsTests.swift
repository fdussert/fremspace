import XCTest
import Foundation
import CoreGraphics
@testable import FremspaceCore

final class RequirementsTests: XCTestCase {
    private let left = DisplayIdentity(vendor: 2, model: 2, serial: 1, name: "Left display")
    private let edge = DisplayIdentity(vendor: 3, model: 3, serial: 7, name: "Strip display")
    private let gone = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Other office")

    func testMissingDesktopsPerDisplay() {
        let configuration = Configuration(id: UUID(), name: "Home", displays: [
            DisplaySpec(identity: left, spaces: [SpaceSpec(label: "Code"), SpaceSpec(label: "Web"), SpaceSpec(label: "Le reste")]),
            DisplaySpec(identity: edge, ignored: true, spaces: [SpaceSpec(label: "a"), SpaceSpec(label: "b")]),
            DisplaySpec(identity: gone, spaces: [SpaceSpec(label: "a"), SpaceSpec(label: "b")]),
        ])
        XCTAssertEqual(missingDesktops(configuration, present: [left: 2, edge: 1]),
                       [MissingDesktops(display: left, needed: 3, present: 2)])
    }

    func testMinimumSizesKeepTheLargest() {
        var minimums = MinimumSizes()
        minimums.record(bundleID: "com.microsoft.Outlook", size: CGSize(width: 770, height: 600))
        minimums.record(bundleID: "com.microsoft.Outlook", size: CGSize(width: 700, height: 650))
        XCTAssertEqual(minimums.minimum(for: "com.microsoft.Outlook"), CGSize(width: 770, height: 650))
        XCTAssertNil(minimums.minimum(for: "com.tinyspeck.slackmacgap"))
    }

    func testTooSmallFlagsOutlookOnAQuarter() {
        var minimums = MinimumSizes()
        minimums.record(bundleID: "com.microsoft.Outlook", size: CGSize(width: 770, height: 650))
        let layout = Layout(slots: [
            Slot(id: "mail", rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.5), rule: Rule(bundleID: "com.microsoft.Outlook")),
            Slot(id: "slack", rect: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5), rule: Rule(bundleID: "com.tinyspeck.slackmacgap")),
        ])
        let frames = ["mail": CGRect(x: 760, y: 41, width: 744, height: 441), "slack": CGRect(x: 8, y: 41, width: 744, height: 441)]
        XCTAssertEqual(tooSmall(frames, layout: layout, minimums: minimums), ["mail": CGSize(width: 770, height: 650)])
    }

    func testOnlyTheRefusedDimensionIsLearned() {
        // Outlook in a 1680 x 441 slot settles at 1680 x 650: only its height is a minimum.
        var minimums = MinimumSizes()
        minimums.record(bundleID: "com.microsoft.Outlook", requested: CGSize(width: 1680, height: 441),
                        actual: CGSize(width: 1680, height: 650), tolerance: 2)
        XCTAssertEqual(minimums.minimum(for: "com.microsoft.Outlook"), CGSize(width: 0, height: 650))
    }

    /// Mission Control's "Automatically rearrange Spaces based on most recent use" reorders desktops,
    /// and Fremspace finds desktops by position: on (or unset, macOS's default) it must warn.
    func testRearrangingSpacesIsWarned() {
        XCTAssertNotNil(SpacesOrder.warning(mruSpaces: nil))
        XCTAssertNotNil(SpacesOrder.warning(mruSpaces: true))
        XCTAssertNotNil(SpacesOrder.warning(mruSpaces: NSNumber(value: 1)))
        XCTAssertNil(SpacesOrder.warning(mruSpaces: false))
        XCTAssertNil(SpacesOrder.warning(mruSpaces: NSNumber(value: 0)))
    }
}
