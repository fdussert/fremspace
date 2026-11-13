import XCTest
@testable import FremspaceCore

final class LinkTests: XCTestCase {
    func testALinkRunsACommandOrShowsADesktopOrAScene() {
        XCTAssertEqual(parseLink(URL(string: "fremspace://run/palette")!), .run("palette"))
        XCTAssertEqual(parseLink(URL(string: "fremspace://run/quick.leftHalf")!), .run("quick.leftHalf"))
        XCTAssertEqual(parseLink(URL(string: "fremspace://desktop/Le%20reste")!), .desktop("Le reste"))
        XCTAssertEqual(parseLink(URL(string: "FREMSPACE://Scene/R%C3%A9union")!), .scene("Réunion"))
    }

    func testALinkRunsWhatShowsGoesToOrResizes() {
        for id in ["palette", "openAdmin", "windowMenu", "reapply", "focusToggle", "slotLeft", "slotDown",
                   "stackNext", "stackPrevious", "drawerLeft", "drawerRight", "scene.1", "scene.4",
                   "quick.leftHalf", "quick.maximize", "quick.restore"] {
            XCTAssertTrue(linkMayRun(id), id)
        }
    }

    func testALinkNeverWritesTheConfigurationPausesParksAWindowOrPressesAMenu() {
        for id in ["slotSwapLeft", "slotSwapRight", "slotSwapUp", "slotSwapDown", "pause",
                   "drawerSendLeft", "drawerSendRight", "splitNew"] {
            XCTAssertFalse(linkMayRun(id), id)
        }
        // What is not known is refused too: a new command has to be let in.
        for id in ["", "lockOnThisDesktop", "quick.", "quick.everything", "scene.0", "scene.x", "Pause"] {
            XCTAssertFalse(linkMayRun(id), id)
        }
    }

    func testAnythingElseIsNotALink() {
        XCTAssertNil(parseLink(URL(string: "https://run/palette")!))
        XCTAssertNil(parseLink(URL(string: "fremspace://run")!))
        XCTAssertNil(parseLink(URL(string: "fremspace://delete/everything")!))
    }
}
