import XCTest
@testable import FremspaceCore

final class AppcastTests: XCTestCase {
    private let changelog = """
    # Changelog

    ## Unreleased

    ## 0.2.0 - 2026-12-01

    - **Scenes.** A scene switches several
      displays at once, see `docs/scenes.md`.
    - Fixed: a <reminder> & its app.

    ### Notes

    Read [the page](https://example.com/notes) first.

    ## 0.1.0

    The first version.
    """

    func testChangelogSectionIsTheBodyUnderItsVersion() {
        XCTAssertEqual(changelogSection(changelog, version: "0.1.0"), "The first version.")
        let section = changelogSection(changelog, version: "0.2.0")
        XCTAssertEqual(section?.hasPrefix("- **Scenes.**"), true)
        XCTAssertEqual(section?.hasSuffix("first."), true)
        XCTAssertEqual(section?.contains("0.1.0"), false)
        // No section, an empty one, or a version that only begins the same: nothing.
        XCTAssertNil(changelogSection(changelog, version: "0.3.0"))
        XCTAssertNil(changelogSection(changelog, version: "Unreleased"))
        XCTAssertNil(changelogSection(changelog, version: "0.2"))
    }

    func testReleaseNotesBecomeLittleHTML() {
        let html = releaseNotesHTML(changelogSection(changelog, version: "0.2.0") ?? "")
        XCTAssertEqual(html, """
        <ul><li><strong>Scenes.</strong> A scene switches several displays at once, see <code>docs/scenes.md</code>.</li>\
        <li>Fixed: a &lt;reminder&gt; &amp; its app.</li></ul>
        <h3>Notes</h3>
        <p>Read <a href="https://example.com/notes">the page</a> first.</p>
        """)
    }

    func testAppcastCarriesTheVersionTheArchiveAndItsSignature() {
        let feed = appcast(version: "0.2.0", url: "https://example.com/a.zip?x=1&y=2", length: 1234, signature: "c2ln",
                           notesHTML: "<p>ok ]]> still text</p>", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(feed.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<rss"))
        XCTAssertTrue(feed.contains("<sparkle:version>0.2.0</sparkle:version>"))
        XCTAssertTrue(feed.contains("<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>"))
        XCTAssertTrue(feed.contains("<pubDate>Thu, 01 Jan 1970 00:00:00 GMT</pubDate>"))
        XCTAssertTrue(feed.contains("url=\"https://example.com/a.zip?x=1&amp;y=2\" length=\"1234\""))
        XCTAssertTrue(feed.contains("sparkle:edSignature=\"c2ln\""))
        // The notes cannot close the CDATA section they sit in.
        XCTAssertTrue(feed.contains("<![CDATA[<p>ok ]]&gt; still text</p>]]>"))
    }
}
