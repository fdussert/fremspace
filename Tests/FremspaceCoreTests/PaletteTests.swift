import XCTest
@testable import FremspaceCore

final class PaletteTests: XCTestCase {
    private let items = [
        PaletteItem(id: "w:1", kind: .window, title: "fremspace — Engine.swift", subtitle: "Visual Studio Code · Code",
                    useKey: "wa:com.microsoft.VSCode"),
        PaletteItem(id: "w:2", kind: .window, title: "Réunion hebdo", subtitle: "Microsoft Teams · Teams"),
        PaletteItem(id: "a:calc", kind: .app, title: "Calculette", keywords: ["Calculator"]),
        PaletteItem(id: "a:code", kind: .app, title: "Visual Studio Code", keywords: ["Code"]),
        PaletteItem(id: "a:slack", kind: .app, title: "Slack"),
        PaletteItem(id: "d:1", kind: .desktop, title: "Code", subtitle: "Desktop 1 of DELL S3221QSA (1)"),
        PaletteItem(id: "c:reapply", kind: .command, title: "Re-apply the layouts"),
    ]

    private func ids(_ query: String, uses: [String: Int] = [:]) -> [String] {
        paletteResults(query, items: items, uses: uses).map(\.id)
    }

    func testAWordMatchesBestAtTheStartThenAWordThenInitialsThenTheMiddle() {
        XCTAssertEqual(paletteScore(word: "slack", in: "slack"), 100)
        XCTAssertEqual(paletteScore(word: "sla", in: "slack"), 90)
        XCTAssertEqual(paletteScore(word: "stu", in: "visual studio code"), 75)
        XCTAssertEqual(paletteScore(word: "vsc", in: "visual studio code"), 60)
        XCTAssertEqual(paletteScore(word: "ack", in: "slack"), 50)
        XCTAssertEqual(paletteScore(word: "slk", in: "slack"), 20)
        XCTAssertNil(paletteScore(word: "x", in: "slack"))
        XCTAssertNil(paletteScore(word: "kcals", in: "slack"))
    }

    func testAccentsAndCaseDoNotCount() {
        XCTAssertEqual(ids("reunion"), ["w:2"])
        XCTAssertEqual(ids("RÉU"), ["w:2"])
    }

    func testAnAppAnswersToItsFileNameToo() {
        XCTAssertEqual(ids("calcula"), ["a:calc"])
        XCTAssertEqual(ids("calcule"), ["a:calc"])
    }

    func testEveryWordOfTheQueryHasToMatch() {
        XCTAssertEqual(ids("engine code"), ["w:1"])
        XCTAssertEqual(ids("engine slack"), [])
    }

    func testWithoutAQueryOnlyTheWindowsInTheOrderGiven() {
        XCTAssertEqual(ids(""), ["w:1", "w:2"])
        XCTAssertEqual(ids("  "), ["w:1", "w:2"])
    }

    func testTheBestMatchComesFirstAndAWindowBeforeAnAppOnATie() {
        // "code": the desktop is the whole word; the app has it as a keyword and as a word.
        XCTAssertEqual(ids("code").first, "d:1")
        XCTAssertEqual(Set(ids("code")), ["d:1", "a:code", "w:1"])
        XCTAssertEqual(ids("re").prefix(2), ["w:2", "c:reapply"])
    }

    func testWhatIsOpenedOftenComesFirst() {
        XCTAssertEqual(ids("code", uses: ["a:code": 9]).first, "a:code")
        // The windows of an app share its count.
        XCTAssertEqual(ids("studio").first, "a:code")
        XCTAssertEqual(ids("studio", uses: ["wa:com.microsoft.VSCode": 30]).first, "w:1")
        XCTAssertNil(paletteScore(word: "reu", in: "re-apply the layouts"))
    }

    func testTheLimitCutsTheList() {
        XCTAssertEqual(paletteResults("", items: items, limit: 1).map(\.id), ["w:1"])
    }

    func testPinnedRowsHeadTheListWhenNothingIsTyped() {
        let front = PaletteItem(id: "w:1", kind: .window, title: "Editor")
        let before = PaletteItem(id: "w:2", kind: .window, title: "Browser")
        let session = PaletteItem(id: "x:agents:12", kind: .extra, title: "Billing fixes")
        let app = PaletteItem(id: "a:notes", kind: .app, title: "Notes")
        let items = [front, before, app, session]
        // In the order they were pinned; a pin whose row is not there now takes no place.
        let rows = paletteResults("", items: items, pins: ["x:agents:12", "x:agents:gone", "a:notes"])
        XCTAssertEqual(rows.map(\.id), ["x:agents:12", "a:notes", "w:1", "w:2"])
        // The window the owner had before stays the one chosen, under the pins.
        XCTAssertEqual(paletteFirstChoice(rows), 3)
        XCTAssertEqual(paletteFirstChoice([front, before]), 1)
        XCTAssertEqual(paletteFirstChoice([session, front]), 1)
        XCTAssertEqual(paletteFirstChoice([session, app]), 0)
        XCTAssertEqual(paletteFirstChoice([]), 0)
        // A query ranks as before: the pins change nothing in it.
        XCTAssertEqual(paletteResults("bro", items: items, pins: ["a:notes"]).map(\.id), ["w:2"])
    }

    func testARowIsPinnedAndUnpinnedButNotAWindow() {
        let session = PaletteItem(id: "x:agents:12", kind: .extra, title: "Billing fixes")
        let window = PaletteItem(id: "w:1", kind: .window, title: "Editor")
        XCTAssertEqual(palettePins([], toggling: session), ["x:agents:12"])
        XCTAssertEqual(palettePins(["a:notes", "x:agents:12"], toggling: session), ["a:notes"])
        XCTAssertNil(palettePins([], toggling: window))
        let full = (0..<palettePinLimit).map { "c:\($0)" }
        XCTAssertNil(palettePins(full, toggling: session))
        // One of a full list can still be taken out.
        XCTAssertEqual(palettePins(full, toggling: PaletteItem(id: "c:0", kind: .command, title: "First"))?.count, palettePinLimit - 1)
    }
}
