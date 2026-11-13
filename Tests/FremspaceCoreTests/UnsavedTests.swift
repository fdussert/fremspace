import XCTest
@testable import FremspaceCore

final class UnsavedTests: XCTestCase {
    private let screen = DisplayIdentity(vendor: 1, model: 1, serial: 1, name: "Built-in")

    private func configuration(_ name: String, desktops: [String] = ["Desktop 1"]) -> Configuration {
        Configuration(id: UUID(), name: name, displays: [DisplaySpec(identity: screen, spaces: desktops.map { SpaceSpec(label: $0) })])
    }

    func testAFileAsSavedHasNothingUnsaved() {
        let saved = Config(configurations: [configuration("Desk")])
        XCTAssertTrue(unsavedChanges(edited: saved, saved: saved).isEmpty)
        XCTAssertEqual(unsavedPlaces(unsavedChanges(edited: saved, saved: saved), in: saved), [])
    }

    func testAChangedConfigurationIsNamedAndTheOthersAreNot() {
        let saved = Config(configurations: [configuration("Desk"), configuration("Travel")])
        var edited = saved
        edited.configurations[1].displays[0].spaces[0].label = "Mail"
        let changes = unsavedChanges(edited: edited, saved: saved)
        XCTAssertEqual(changes.configurations, [saved.configurations[1].id])
        XCTAssertFalse(changes.scenes)
        XCTAssertEqual(unsavedPlaces(changes, in: edited), ["Travel"])
    }

    func testANewConfigurationAndADeletedOneAreBothUnsaved() {
        let saved = Config(configurations: [configuration("Desk")])
        var edited = saved
        edited.configurations = [configuration("")]
        let changes = unsavedChanges(edited: edited, saved: saved)
        XCTAssertEqual(changes.configurations, [edited.configurations[0].id])
        XCTAssertEqual(changes.deleted, 1)
        XCTAssertEqual(unsavedPlaces(changes, in: edited), ["Untitled", "a deleted configuration"])
    }

    func testAChangedSceneMarksItsConfigurationAndTheScenes() {
        let saved = Config(configurations: [configuration("Desk")])
        var edited = saved
        edited.configurations[0].scenes = [Scene(id: UUID(), name: "Meeting")]
        let changes = unsavedChanges(edited: edited, saved: saved)
        XCTAssertTrue(changes.scenes)
        XCTAssertEqual(changes.configurations, [saved.configurations[0].id])
    }

    func testSettingsAndShortcutsAreTheirPages() {
        let saved = Config(configurations: [configuration("Desk")])
        var edited = saved
        edited.notchMap.toggle()
        edited.hyperKey = true
        let changes = unsavedChanges(edited: edited, saved: saved)
        XCTAssertTrue(changes.general)
        XCTAssertTrue(changes.shortcuts)
        XCTAssertTrue(changes.configurations.isEmpty)
        XCTAssertEqual(unsavedPlaces(changes, in: edited), ["General", "Shortcuts"])
        // The list of the apps that may float is a setting of the General page too.
        var listed = saved
        listed.floatingApps = ["com.apple.finder"]
        XCTAssertTrue(unsavedChanges(edited: listed, saved: saved).general)
    }

    func testAListReadsAsASentenceDoes() {
        XCTAssertEqual(listed([]), "")
        XCTAssertEqual(listed(["Desk"]), "Desk")
        XCTAssertEqual(listed(["Desk", "Shortcuts"]), "Desk and Shortcuts")
        XCTAssertEqual(listed(["Desk", "Travel", "General"]), "Desk, Travel and General")
    }
}
