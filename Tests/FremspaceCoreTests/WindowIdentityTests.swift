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

    func testProfileFromATitleInAnotherLanguageOrChannel() {
        let chrome = "com.google.Chrome"
        // French Brave puts an en dash before its name; French Chrome keeps the hyphen.
        XCTAssertEqual(browserProfile(fromTitle: "Réglages du compte – Brave – Perso", bundleID: brave), "Perso")
        XCTAssertEqual(browserProfile(fromTitle: "Boîte de réception - Google Chrome – Travail", bundleID: chrome), "Travail")
        XCTAssertNil(browserProfile(fromTitle: "Réglages du compte – Brave", bundleID: brave))
        XCTAssertNil(browserProfile(fromTitle: "Boîte de réception - Google Chrome", bundleID: chrome))
        // Whatever dash stands before the profile.
        XCTAssertEqual(browserProfile(fromTitle: "Inbox - Google Chrome - Work", bundleID: chrome), "Work")
        // The channels have their own names and their own apps.
        XCTAssertEqual(browserProfile(fromTitle: "Docs - Brave Beta – Work", bundleID: "com.brave.Browser.beta"), "Work")
        XCTAssertEqual(browserProfile(fromTitle: "Docs \u{2011} Brave Nightly – Work", bundleID: "com.brave.Browser.nightly"), "Work")
        XCTAssertEqual(browserProfile(fromTitle: "Docs - Google Chrome Canary – Work", bundleID: "com.google.Chrome.canary"), "Work")
        // A page named after the browser is not a profile: the title ends with the browser's name.
        XCTAssertNil(browserProfile(fromTitle: "Review - Brave - Brave", bundleID: brave))
        XCTAssertNil(browserProfile(fromTitle: "Accueil – Brave – Wikipédia – Brave", bundleID: brave))
        XCTAssertEqual(browserProfile(fromTitle: "Review - Brave - Brave – Work", bundleID: brave), "Work")
        // A profile's own name may hold a dash.
        XCTAssertEqual(browserProfile(fromTitle: "Inbox - Google Chrome – Client - Work", bundleID: chrome), "Client - Work")
        XCTAssertEqual(browserProfile(fromTitle: "Download - Brave - Fast - Brave – Client - Work", bundleID: brave), "Client - Work")
        XCTAssertNil(browserProfile(fromTitle: "Download - Brave - Fast - Brave", bundleID: brave))
        // The browser's name inside a word, or without a dash after it, starts no profile.
        XCTAssertNil(browserProfile(fromTitle: "Inbox - Google Chrome (Incognito)", bundleID: chrome))
        XCTAssertNil(browserProfile(fromTitle: "Bravest - Hearts", bundleID: brave))
        // A profile is a name, not the browser's.
        XCTAssertEqual(browserProfile(fromTitle: "Brave – Work", bundleID: brave), "Work")
        XCTAssertNil(browserProfile(fromTitle: "Work - Brave", bundleID: brave))
    }

    func testTabTitleNoiseIsRemovedInFrench() {
        XCTAssertEqual(normalizedTabTitle("Boîte de réception - Onglet inactif - 123\u{00a0}Mo libérés"), "Boîte de réception")
        XCTAssertEqual(normalizedTabTitle("Boîte de réception - Utilisation de la mémoire - 169 Mo"), "Boîte de réception")
        XCTAssertEqual(normalizedTabTitle("Boîte de réception - Onglet inactif"), "Boîte de réception")
        XCTAssertEqual(normalizedTabTitle("Docs - High memory usage - 1.2 GB"), "Docs")
    }

    func testTabTitleNoiseIsRemoved() {
        XCTAssertEqual(normalizedTabTitle("App Store Connect - Memory usage - 169 MB"), "App Store Connect")
        XCTAssertEqual(normalizedTabTitle("App Store Connect - Inactive tab - 61.9 MB"), "App Store Connect")
        XCTAssertEqual(normalizedTabTitle("GitHub"), "GitHub")
        // A tab put to sleep says what it gave back.
        XCTAssertEqual(normalizedTabTitle("App Store Connect - Inactive tab - 123 MB freed"), "App Store Connect")
        XCTAssertEqual(normalizedTabTitle("App Store Connect - Inactive tab - 61.9 MB freed"), "App Store Connect")
        // A title that merely ends like a size keeps its words.
        XCTAssertEqual(normalizedTabTitle("Pricing - 20 GB plan"), "Pricing - 20 GB plan")
    }

    func testAWindowIsRecognisedWhateverItsTabsSleep() {
        // Remembered by a build that left "freed" on, then seen after a restart, every tab awake.
        var before = identity(["Jira", "Mail", "Docs", "Wiki"], title: "Jira - Brave – Work")
        before.tabs = ["Docs - Inactive tab - 61.9 MB freed", "Jira", "Mail - Inactive tab - 123 MB freed",
                       "Wiki - Inactive tab - 80 MB freed"]
        let after = identity(["Jira", "Mail", "Docs", "Wiki"], title: "Jira - Brave – Work")
        XCTAssertEqual(similarity(before, after), 1)
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
