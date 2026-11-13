import CoreGraphics
import XCTest
@testable import FremspaceCore

final class WindowIdentityTests: XCTestCase {
    private let brave = "com.brave.Browser"

    private func identity(_ tabs: [String], title: String = "", profile: String? = "Work",
                          bundleID: String = "com.brave.Browser", document: String? = nil,
                          size: CGSize = CGSize(width: 1000, height: 800)) -> WindowIdentity {
        WindowIdentity(bundleID: bundleID, profile: profile, document: document, title: title, tabs: tabs, size: size)
    }

    func testProfileFromBraveTitle() {
        XCTAssertEqual(browserProfile(fromTitle: "Release - Staging – Part of group ⌛Docs - Brave – Work", bundleID: brave), "Work")
        XCTAssertEqual(browserProfile(fromTitle: "Réglages du compte - Brave – Perso", bundleID: brave), "Perso")
        XCTAssertNil(browserProfile(fromTitle: "Inbox - Brave", bundleID: brave))
        XCTAssertNil(browserProfile(fromTitle: "A - B – C - Brave", bundleID: brave))
        XCTAssertNil(browserProfile(fromTitle: "Documents – Perso", bundleID: "com.apple.finder"))
    }

    func testTabTitleNoiseIsRemoved() {
        XCTAssertEqual(normalizedTabTitle("App Store Connect - Memory usage - 169 MB"), "App Store Connect")
        XCTAssertEqual(normalizedTabTitle("App Store Connect - Inactive tab - 61.9 MB"), "App Store Connect")
        XCTAssertEqual(normalizedTabTitle("GitHub"), "GitHub")
    }

    func testSameProfileWindowsKeepTheirPlaceAfterRelaunch() {
        let remembered = [identity(["Jira", "Mail", "Docs"], title: "Jira - Brave – Work"),
                          identity(["GitHub", "Cloudflare"], title: "GitHub - Brave – Work")]
        // After the reboot each window shows another active tab: titles swapped, tabs did not.
        let live: [UInt32: WindowIdentity] = [10: identity(["GitHub - Memory usage - 12 MB", "Cloudflare"], title: "Jira - Brave – Work"),
                    11: identity(["Jira", "Mail", "Docs - Inactive tab"], title: "GitHub - Brave – Work")]
        XCTAssertEqual(matchIdentities(live: live, remembered: remembered), [10: 1, 11: 0])
    }

    func testDocumentWins() {
        let sublime = "com.sublimetext.4"
        let remembered = [identity([], title: "notes.md", profile: nil, bundleID: sublime, document: "file:///a/notes.md"),
                          identity([], title: "todo.md", profile: nil, bundleID: sublime, document: "file:///a/todo.md")]
        let live: [UInt32: WindowIdentity] = [20: identity([], title: "todo.md — edited", profile: nil, bundleID: sublime, document: "file:///a/todo.md"),
                    21: identity([], title: "notes.md — edited", profile: nil, bundleID: sublime, document: "file:///a/notes.md")]
        XCTAssertEqual(matchIdentities(live: live, remembered: remembered), [20: 1, 21: 0])
    }

    func testDifferentProfileNeverMatches() {
        let remembered = [identity(["GitHub"], profile: "Perso")]
        let live: [UInt32: WindowIdentity] = [10: identity(["GitHub"], profile: "Work")]
        XCTAssertEqual(similarity(live[10]!, remembered[0]), 0)
        XCTAssertEqual(matchIdentities(live: live, remembered: remembered), [:])
    }
}
