import XCTest
@testable import FremspaceCore

final class ShortcutsTests: XCTestCase {
    func testModifiersCompareWhateverTheirOrder() {
        XCTAssertEqual(Shortcut(keyCode: 37, modifiers: ["command", "control"]),
                       Shortcut(keyCode: 37, modifiers: ["control", "command"]))
    }

    func testAShortcutNeedsMoreThanShift() {
        XCTAssertFalse(Shortcut(keyCode: 37).isUsable)
        XCTAssertFalse(Shortcut(keyCode: 37, modifiers: ["shift"]).isUsable)
        XCTAssertTrue(Shortcut(keyCode: 37, modifiers: ["option"]).isUsable)
        // No shortcut at all is a valid choice.
        XCTAssertTrue(Shortcut(keyCode: nil).isUsable)
    }

    func testAMisspeltModifierMakesTheShortcutUnusableInsteadOfAnotherShortcut() throws {
        // Written by hand: "cmd" for "command". Read as ⌃⌥K it would take a key from every app.
        let json = Data(#"{"keyCode":40,"modifiers":["cmd","option","control"]}"#.utf8)
        let shortcut = try JSONDecoder().decode(Shortcut.self, from: json)
        XCTAssertFalse(shortcut.isUsable)
        XCTAssertEqual(shortcut.modifiers, ["control", "option", "cmd"])
        // It is written back as it was: the owner finds the word to correct.
        let again = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(again, shortcut)
        // The only modifier, misspelt: not the bare key either.
        XCTAssertFalse(Shortcut(keyCode: 40, modifiers: ["Command"]).isUsable)
    }

    func testConflictNamesTheOtherCommand() {
        let hyperL = Shortcut(keyCode: 37, modifiers: ["control", "option", "command"])
        let effective = ["drawerLeft": hyperL, "pause": Shortcut(keyCode: 35, modifiers: ["control", "option", "command"]),
                         "stackNext": Shortcut(keyCode: nil)]
        XCTAssertEqual(shortcutConflict(hyperL, for: "pause", effective: effective), "drawerLeft")
        XCTAssertNil(shortcutConflict(hyperL, for: "drawerLeft", effective: effective))
        XCTAssertNil(shortcutConflict(Shortcut(keyCode: nil), for: "pause", effective: effective))
    }

    func testShortcutsRoundTripAndOlderFilesHaveNone() throws {
        let custom = Config(configurations: [], shortcuts: ["stackNext": Shortcut(keyCode: 48, modifiers: ["option"]),
                                                            "pause": Shortcut(keyCode: nil)])
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded, custom)
        let plain = try JSONEncoder().encode(Config(configurations: []))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("shortcuts"))
        let older = try JSONDecoder().decode(Config.self, from: plain)
        XCTAssertTrue(older.shortcuts.isEmpty)
    }
}
