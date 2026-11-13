import CoreGraphics
import XCTest
@testable import FremspaceCore

final class EngineRulesTests: XCTestCase {
    private let laptop = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")
    private let left = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "Left")
    private let right = DisplayIdentity(vendor: 2, model: 2, serial: 3, name: "Right")

    private func configuration(_ name: String, _ displays: [DisplayIdentity]) -> Configuration {
        Configuration(id: UUID(), name: name, displays: displays.map { DisplaySpec(identity: $0, spaces: []) })
    }

    func testTheDockChangingDisplayIsNotADisplayChange() {
        func area(_ identity: DisplayIdentity, x: CGFloat, dock: CGFloat = 0) -> DisplayArea {
            DisplayArea(identity: identity, frame: CGRect(x: x, y: 0, width: 1000, height: 800),
                        visible: CGRect(x: x, y: 30, width: 1000, height: 770 - dock))
        }
        let before = [area(laptop, x: 0, dock: 60), area(left, x: 1000)]
        // The same notice from macOS, and nothing about the displays is different.
        XCTAssertEqual(displaysChange(from: before, to: [area(left, x: 1000), area(laptop, x: 0, dock: 60)]), .none)
        // The Dock went from the laptop to the left display: only the room it leaves changed.
        XCTAssertEqual(displaysChange(from: before, to: [area(laptop, x: 0), area(left, x: 1000, dock: 60)]), .visibleArea)
        // A display unplugged, plugged in, moved in the arrangement or given another resolution.
        XCTAssertEqual(displaysChange(from: before, to: [area(laptop, x: 0, dock: 60)]), .displays)
        XCTAssertEqual(displaysChange(from: before, to: before + [area(right, x: 2000)]), .displays)
        XCTAssertEqual(displaysChange(from: before, to: [area(laptop, x: 0, dock: 60), area(left, x: -1000)]), .displays)
        XCTAssertEqual(displaysChange(from: before, to: [area(laptop, x: 0, dock: 60), area(right, x: 1000)]), .displays)
    }

    func testPicksConfigurationWithMostMatchingDisplays() {
        let config = Config(configurations: [configuration("Train", [laptop]),
                                             configuration("Desk", [laptop, left, right])])
        XCTAssertEqual(chooseConfiguration(config, connected: [right, laptop, left])?.name, "Desk")
        XCTAssertEqual(chooseConfiguration(config, connected: [laptop])?.name, "Train")
    }

    func testNoConfigurationWhenADisplayIsMissing() {
        let config = Config(configurations: [configuration("Desk", [laptop, left])])
        XCTAssertNil(chooseConfiguration(config, connected: [laptop, right]))
    }

    func testAnIgnoredDisplayIsOptional() {
        var desk = configuration("Desk", [laptop, left, right])
        desk.displays[2].ignored = true
        let config = Config(configurations: [desk])
        XCTAssertEqual(chooseConfiguration(config, connected: [laptop, left])?.name, "Desk")
        XCTAssertEqual(chooseConfiguration(config, connected: [laptop, left, right])?.name, "Desk")
        // A display Fremspace arranges is still required.
        XCTAssertNil(chooseConfiguration(config, connected: [laptop, right]))
        // And a configuration made of ignored displays only never applies.
        desk.displays[0].ignored = true
        desk.displays[1].ignored = true
        XCTAssertNil(chooseConfiguration(Config(configurations: [desk]), connected: [laptop, left, right]))
    }

    func testTieGoesToFirstConfiguration() {
        let config = Config(configurations: [configuration("A", [laptop]), configuration("B", [laptop])])
        XCTAssertEqual(chooseConfiguration(config, connected: [laptop])?.name, "A")
    }

    func testNearestSlotByCentre() {
        let frames = ["ide": CGRect(x: 8, y: 33, width: 2052, height: 1399),
                      "web": CGRect(x: 2068, y: 33, width: 1364, height: 1399)]
        XCTAssertEqual(nearestSlot(to: CGRect(x: 1900, y: 40, width: 1500, height: 1300), among: frames), "web")
        XCTAssertEqual(nearestSlot(to: CGRect(x: 30, y: 40, width: 2000, height: 1300), among: frames), "ide")
        XCTAssertNil(nearestSlot(to: .zero, among: [:]))
    }

    /// Two connected displays with the same identity (serial 0, or a placeholder like the Xeneon's)
    /// cannot be told apart: a configuration that places windows on that identity must not run.
    func testDuplicateIdentityOfAConfiguredDisplayIsAmbiguous() {
        let twin = DisplayIdentity(vendor: 2, model: 2, serial: 2, name: "Left twin")
        let home = configuration("Home", [laptop, left])
        XCTAssertEqual(ambiguousDisplay(connected: [laptop, left, twin], in: home), left)
        XCTAssertNil(ambiguousDisplay(connected: [laptop, left, right], in: home))
        var ignoring = home
        ignoring.displays[1].ignored = true
        XCTAssertNil(ambiguousDisplay(connected: [laptop, left, twin], in: ignoring), "an ignored display places nothing")
        XCTAssertNil(ambiguousDisplay(connected: [laptop, right, right], in: home), "twins the configuration does not use are harmless")
    }
}
