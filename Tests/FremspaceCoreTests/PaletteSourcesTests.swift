import XCTest
@testable import FremspaceCore

final class PaletteSourcesTests: XCTestCase {
    private func items(_ json: String) -> [SourceItem]? {
        sourceItems(from: Data(json.utf8))
    }

    func testASourceListsRowsWithWhatToDoWhenChosen() {
        let rows = items("""
        {"items": [
          {"title": "Billing fixes", "subtitle": "agent · website", "arg": "session-12", "app": "com.example.terminal",
           "tag": "working", "keywords": ["invoices"]},
          {"title": "Docs", "url": "https://example.org/docs"}
        ]}
        """)
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?.first, SourceItem(title: "Billing fixes", subtitle: "agent · website", arg: "session-12",
                                               app: "com.example.terminal", tag: "working", keywords: ["invoices"]))
        XCTAssertEqual(rows?.last?.url, URL(string: "https://example.org/docs"))
        // The list alone is read too.
        XCTAssertEqual(items(#"[{"title": "One", "arg": "1"}]"#)?.map(\.title), ["One"])
    }

    func testWhatIsNotAListIsNotRead() {
        XCTAssertNil(items("usage: tool [options]"))
        XCTAssertNil(items(#"{"error": "not running"}"#))
        XCTAssertNil(items(#""just a string""#))
        XCTAssertEqual(items(#"{"items": []}"#), [])
        // More than a source may send.
        XCTAssertNil(sourceItems(from: Data(count: SourceLimit.bytes + 1)))
    }

    func testARowThatCannotBeShownOrChosenIsLeftOut() {
        let rows = items("""
        [{"title": "", "arg": "1"},
         {"title": "No action"},
         {"subtitle": "no title", "arg": "2"},
         "not a row",
         {"title": "Kept", "arg": "3"},
         {"title": "Only an app", "app": "com.example.editor"},
         {"title": "A path is not a link", "url": "/tmp/somewhere"}]
        """)
        XCTAssertEqual(rows?.map(\.title), ["Kept", "Only an app"])
        let long = String(repeating: "a", count: SourceLimit.arg + 1)
        XCTAssertEqual(items(#"[{"title": "Too long to hand back", "arg": "\#(long)"}]"#), [])
    }

    func testTextIsOneLineAndCut() {
        let title = String(repeating: "t", count: SourceLimit.title + 50)
        let rows = items(#"[{"title": "\#(title)", "subtitle": "first\nsecond\tthird", "tag": "a very long state word that goes on", "arg": "1"}]"#)
        XCTAssertEqual(rows?.first?.title.count, SourceLimit.title)
        XCTAssertEqual(rows?.first?.subtitle, "first second third")
        XCTAssertEqual(rows?.first?.tag.count, SourceLimit.tag)
    }

    func testNoMoreRowsThanTheLimit() {
        let many = (0..<SourceLimit.items + 20).map { #"{"title": "Row \#($0)", "arg": "\#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(items("[\(many)]")?.count, SourceLimit.items)
    }

    func testOnlyTheOwnersOwnExecutablesAreRun() {
        XCTAssertTrue(sourceMayRun(name: "tmux", isRegularFile: true, permissions: 0o755, owner: 501, user: 501))
        XCTAssertTrue(sourceMayRun(name: "tmux.sh", isRegularFile: true, permissions: 0o700, owner: 501, user: 501))
        // Not executable: a note left in the folder.
        XCTAssertFalse(sourceMayRun(name: "README.md", isRegularFile: true, permissions: 0o644, owner: 501, user: 501))
        // Somebody else's, or one somebody else may write.
        XCTAssertFalse(sourceMayRun(name: "tmux", isRegularFile: true, permissions: 0o755, owner: 0, user: 501))
        XCTAssertFalse(sourceMayRun(name: "tmux", isRegularFile: true, permissions: 0o775, owner: 501, user: 501))
        XCTAssertFalse(sourceMayRun(name: "tmux", isRegularFile: true, permissions: 0o757, owner: 501, user: 501))
        XCTAssertFalse(sourceMayRun(name: ".hidden", isRegularFile: true, permissions: 0o755, owner: 501, user: 501))
        XCTAssertFalse(sourceMayRun(name: "folder", isRegularFile: false, permissions: 0o755, owner: 501, user: 501))
    }

    func testARowOfASourceIsFoundByItsTitleAndItsSource() {
        let row = paletteItem(SourceItem(title: "Billing fixes", subtitle: "agent · website", arg: "session-12"), source: "agents")
        XCTAssertEqual(row.id, "x:agents:session-12")
        XCTAssertEqual(row.kind, .extra)
        XCTAssertEqual(paletteResults("bill", items: [row]).map(\.id), ["x:agents:session-12"])
        XCTAssertEqual(paletteResults("agents", items: [row]).count, 1)
        // The same row from two sources stays two rows.
        let other = paletteItem(SourceItem(title: "Billing fixes", arg: "session-12"), source: "tabs")
        XCTAssertEqual(paletteResults("billing", items: [row, other]).count, 2)
        XCTAssertEqual(sourceName(file: "tmux.sh"), "tmux")
        XCTAssertEqual(sourceName(file: "agents"), "agents")
    }

    func testAmongEqualMatchesAWindowComesBeforeASourceRowBeforeAnApp() {
        let app = PaletteItem(id: "a:notes", kind: .app, title: "Notes")
        let extra = paletteItem(SourceItem(title: "Notes", arg: "1"), source: "agents")
        let window = PaletteItem(id: "w:1", kind: .window, title: "Notes")
        XCTAssertEqual(paletteResults("notes", items: [app, extra, window]).map(\.kind), [.window, .extra, .app])
        // Without a query the palette lists the windows only, as before.
        XCTAssertEqual(paletteResults("", items: [app, extra, window]).map(\.kind), [.window])
    }

    func testASourceRunsWithTheUsualPlacesOfTools() {
        let environment = sourceEnvironment(home: "/Users/someone", user: "someone", temporary: "/tmp/x")
        XCTAssertEqual(environment["PATH"], "/Users/someone/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["HOME"], "/Users/someone")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/x")
    }
}
