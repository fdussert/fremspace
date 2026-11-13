import CoreGraphics
import XCTest
@testable import FremspaceCore

final class GeometryTests: XCTestCase {
    private let codeLayout = Layout(slots: [
        Slot(id: "ide", rect: UnitRect(x: 0, y: 0, w: 0.6, h: 1), rule: Rule(bundleID: "com.microsoft.VSCode")),
        Slot(id: "web", rect: UnitRect(x: 0.6, y: 0, w: 0.4, h: 1), rule: Rule(bundleID: "com.brave.Browser")),
    ])
    private let visible = CGRect(x: 0, y: 25, width: 3440, height: 1415)

    func testSnap() {
        XCTAssertEqual(Fractions.snap(0.58), 0.6)
        XCTAssertEqual(Fractions.snap(0.36), 1.0 / 3)
        XCTAssertEqual(Fractions.snap(0.97), 1)
    }

    func testEighthsOnlyOnLargeDisplays() {
        XCTAssertEqual(Fractions.stops(forWidth: 1512), Fractions.stops)
        let wide = Fractions.stops(forWidth: 3360)
        XCTAssertTrue(wide.contains(0.375) && wide.contains(0.625))
        XCTAssertEqual(wide, wide.sorted())
        XCTAssertEqual(Fractions.snap(0.37, width: 3360), 0.375)
        XCTAssertEqual(Fractions.snap(0.36, width: 1512), 1.0 / 3)
    }

    func testAxConversion() {
        XCTAssertEqual(axRect(fromAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1415), primaryHeight: 1440),
                       CGRect(x: 0, y: 25, width: 3440, height: 1415))
        XCTAssertEqual(axRect(fromAppKit: CGRect(x: 0, y: 1440, width: 3024, height: 1964), primaryHeight: 1440),
                       CGRect(x: 0, y: -1964, width: 3024, height: 1964))
    }

    func testSplitFrames() {
        let frames = slotFrames(layout: codeLayout, focus: nil, visible: visible, gap: 8)
        XCTAssertEqual(frames["ide"], CGRect(x: 8, y: 33, width: 2052, height: 1399))
        XCTAssertEqual(frames["web"], CGRect(x: 2068, y: 33, width: 1364, height: 1399))
    }

    func testFocusFrame() {
        let frames = slotFrames(layout: codeLayout, focus: "ide", visible: visible, gap: 8)
        XCTAssertEqual(frames["ide"], CGRect(x: 8, y: 33, width: 3424, height: 1399))
        XCTAssertEqual(frames["web"], CGRect(x: 2068, y: 33, width: 1364, height: 1399))
    }

    func testUnknownDisplayIsFree() {
        let known = DisplayIdentity(vendor: 1, model: 2, serial: 3, name: "Left")
        let edge = DisplayIdentity(vendor: 9, model: 9, serial: 9, name: "Edge")
        let configuration = Configuration(id: UUID(), name: "Desk", displays: [
            DisplaySpec(identity: known, spaces: [SpaceSpec(label: "Code", layout: codeLayout)]),
            DisplaySpec(identity: edge, ignored: true, spaces: []),
        ])
        XCTAssertNil(displaySpec(for: DisplayIdentity(vendor: 4, model: 5, serial: 6, name: "Other"), in: configuration))
        XCTAssertNil(displaySpec(for: edge, in: configuration))
        XCTAssertEqual(displaySpec(for: known, in: configuration)?.spaces.first?.label, "Code")
    }

    func testDisplayMatchIgnoresName() {
        // macOS renames identical monitors "(1)" / "(2)" depending on plug order.
        let a = DisplayIdentity(vendor: 4268, model: 53511, serial: 1002, name: "DELL S3221QSA (1)")
        let b = DisplayIdentity(vendor: 4268, model: 53511, serial: 1002, name: "DELL S3221QSA (2)")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
