import XCTest
@testable import FremspaceCore

final class HyperTests: XCTestCase {
    private let effective: [String: Shortcut] = [
        "focusToggle": Shortcut(keyCode: 49, modifiers: ["control", "option", "command"]),
        "stackNext": Shortcut(keyCode: 48, modifiers: ["command", "control", "option"]),
        "stackPrevious": Shortcut(keyCode: 48, modifiers: ["control", "option", "command", "shift"]),
        "quick.leftHalf": Shortcut(keyCode: 123, modifiers: ["control", "option"]),
        "pause": Shortcut(keyCode: nil),
    ]

    func testHyperPlusAKeyRunsTheCommandOnControlOptionCommand() {
        XCTAssertEqual(hyperOutcome(keyCode: 49, shift: false, effective: effective), .run("focusToggle"))
        XCTAssertEqual(hyperOutcome(keyCode: 48, shift: false, effective: effective), .run("stackNext"))
        XCTAssertEqual(hyperOutcome(keyCode: 48, shift: true, effective: effective), .run("stackPrevious"))
    }

    func testAnyOtherKeyGoesOnWithTheModifiers() {
        // ⌃⌥← is not a Hyper shortcut, and a command without shortcut answers to nothing.
        XCTAssertEqual(hyperOutcome(keyCode: 123, shift: false, effective: effective), .addModifiers)
        XCTAssertEqual(hyperOutcome(keyCode: 49, shift: true, effective: effective), .addModifiers)
        XCTAssertEqual(hyperOutcome(keyCode: 7, shift: false, effective: effective), .addModifiers)
    }

    private let other = KeyMapping(source: 0x7_0000_0064, destination: 0x7_0000_0035)
    private let escape = KeyMapping(source: KeyMapping.capsLock, destination: 0x7_0000_0029)

    func testTurningHyperOnAddsItsMappingAndKeepsTheOthers() {
        var change = hyperMappingChange([], hyper: true, record: nil)
        XCTAssertEqual(change.mappings, [.hyper])
        XCTAssertEqual(change.record, HyperMapping())
        change = hyperMappingChange([other], hyper: true, record: nil)
        XCTAssertEqual(change.mappings, [other, .hyper])
        XCTAssertEqual(change.record, HyperMapping())
        // Already Fremspace's own (a restart, a save of the configuration): nothing changes.
        change = hyperMappingChange([other, .hyper], hyper: true, record: HyperMapping(replaced: [escape]))
        XCTAssertNil(change.mappings)
        XCTAssertEqual(change.record, HyperMapping(replaced: [escape]))
    }

    func testCapsLockMappedToSomethingElseGivesWayAndComesBack() {
        let on = hyperMappingChange([other, escape], hyper: true, record: nil)
        XCTAssertEqual(on.mappings, [other, .hyper])
        XCTAssertEqual(on.record, HyperMapping(replaced: [escape]))
        let off = hyperMappingChange([other, .hyper], hyper: false, record: on.record)
        XCTAssertEqual(off.mappings, [other, escape])
        XCTAssertNil(off.record)
    }

    func testTurningHyperOffRemovesOnlyAMappingFremspaceSet() {
        let off = hyperMappingChange([other, .hyper], hyper: false, record: HyperMapping())
        XCTAssertEqual(off.mappings, [other])
        XCTAssertNil(off.record)
        // The setting is off and Fremspace never set anything: another tool's Caps Lock → F18
        // (the hidutil recipe for a Hyper key) is not Fremspace's to remove, nor anything else.
        for current in [[other, .hyper], [other], [escape], []] {
            let untouched = hyperMappingChange(current, hyper: false, record: nil)
            XCTAssertNil(untouched.mappings)
            XCTAssertNil(untouched.record)
        }
    }

    func testAMappingThatWasThereBeforeIsNotFremspacesToRemove() {
        // Hyper switched on while another tool already maps Caps Lock to F18.
        let on = hyperMappingChange([.hyper], hyper: true, record: nil)
        XCTAssertNil(on.mappings)
        XCTAssertNil(on.record)
        XCTAssertNil(hyperMappingChange([.hyper], hyper: false, record: on.record).mappings)
    }

    func testARecordFromASessionThatEndedPutsNothingBack() {
        // The mapping went with the session (a restart of the Mac): what it had replaced then is
        // not put back over what the keyboard has now.
        let off = hyperMappingChange([other], hyper: false, record: HyperMapping(replaced: [escape]))
        XCTAssertNil(off.mappings)
        XCTAssertNil(off.record)
        // Turned on again, the record is made anew from what is there now.
        let on = hyperMappingChange([other], hyper: true, record: HyperMapping(replaced: [escape]))
        XCTAssertEqual(on.mappings, [other, .hyper])
        XCTAssertEqual(on.record, HyperMapping())
    }

    func testTheRecordIsKeptInTheStateAndOlderStatesHaveNone() throws {
        var state = FremspaceState()
        state.hyperMapping = HyperMapping(replaced: [escape])
        let decoded = try JSONDecoder().decode(FremspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.hyperMapping, state.hyperMapping)
        let older = try JSONDecoder().decode(FremspaceState.self, from: Data("{}".utf8))
        XCTAssertNil(older.hyperMapping)
    }
}
