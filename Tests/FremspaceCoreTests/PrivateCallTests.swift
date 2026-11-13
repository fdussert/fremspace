import XCTest
@testable import FremspaceCore

final class PrivateCallTests: XCTestCase {
    func testWithEveryCallFremspaceRuns() {
        XCTAssertNil(missingCallsReason([]))
    }

    func testWithoutACallThatReadsDesktopsOrWindowsNothingIsApplied() {
        XCTAssertEqual(missingCallsReason([.spacesForWindows]),
                       "This macOS lacks a call Fremspace needs (CGSCopySpacesForWindows)")
        // Named in one order, whatever the order they were found missing in.
        XCTAssertEqual(missingCallsReason([.windowOfElement, .processForPID, .mainConnection]),
                       "This macOS lacks a call Fremspace needs (CGSMainConnectionID, _AXUIElementGetWindow)")
    }

    func testWithoutAnotherCallFremspaceStillRunsAndDoesLess() {
        XCTAssertNil(missingCallsReason([.processForPID, .dockNotification, .keyboardClient, .keyboardCopyProperty,
                                         .keyboardSetProperty]))
        XCTAssertEqual(PrivateCall.processForPID.loss, .oneWindowForward)
        XCTAssertEqual(PrivateCall.dockNotification.loss, .addingDesktops)
        XCTAssertEqual(Set(PrivateCall.allCases.filter { $0.loss == .hyperKey }),
                       [.keyboardClient, .keyboardCopyProperty, .keyboardSetProperty])
    }

    func testAMissingCallIsSaidOnTheStatusPage() {
        var facts = AttentionFacts()
        // Placing is lost: said once, in place of "no configuration is applied".
        facts.idle = .other("This macOS lacks a call Fremspace needs (CGSCopySpacesForWindows)")
        facts.missingCalls = [.spacesForWindows, .processForPID]
        var items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["calls.placing", "calls.oneWindowForward"])
        XCTAssertEqual(items.map(\.level), [.blocking, .note])
        XCTAssertTrue(items[0].detail.contains("CGSCopySpacesForWindows"))
        // The Hyper key only matters to who switched it on, and is then not put on Accessibility.
        facts = AttentionFacts()
        facts.missingCalls = [.keyboardSetProperty, .dockNotification]
        XCTAssertEqual(attentionItems(facts).map(\.id), ["calls.addingDesktops"])
        facts.config.hyperKey = true
        items = attentionItems(facts)
        XCTAssertEqual(items.map(\.id), ["calls.hyperKey", "calls.addingDesktops"])
        XCTAssertNil(items[0].fix)
    }
}
