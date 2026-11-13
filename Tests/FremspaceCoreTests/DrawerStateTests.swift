import XCTest
import CoreGraphics
@testable import FremspaceCore

final class DrawerStateTests: XCTestCase {
    private let right = DisplayIdentity(vendor: 4268, model: 53511, serial: 2, name: "Right")
    private let left = DisplayIdentity(vendor: 4268, model: 53511, serial: 1, name: "Left")
    private var browse: DisplayIdentity { right }
    private var other: DisplayIdentity { left }

    func testSendStacksFrontFirst() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(2, to: browse, slot: "left.top")
        XCTAssertEqual(s.stacks(browse)["left.top"], [2, 1])
        XCTAssertEqual(s.display(of: 1), browse)
        XCTAssertEqual(s.slot(of: 1), "left.top")
        s.bringToFront(1)
        XCTAssertEqual(s.stacks(browse)["left.top"], [1, 2])
    }

    func testSendingAMemberAgainMovesIt() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(1, to: browse, slot: "left.bottom")
        XCTAssertEqual(s.stacks(browse)["left.top"] ?? [], [])
        XCTAssertEqual(s.stacks(browse)["left.bottom"], [1])
    }

    func testMovingTheOnlyMemberKeepsTheDrawerOpen() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.setOpen(browse, true)
        s.send(1, to: browse, slot: "left.bottom")
        XCTAssertTrue(s.isOpen(browse))
        XCTAssertEqual(s.stacks(browse)["left.bottom"], [1])
    }

    func testNeighbourSlotTieGoesToTheUpperSlot() {
        let frames = ["l": CGRect(x: 0, y: 0, width: 500, height: 1000),
                      "rt": CGRect(x: 500, y: 0, width: 500, height: 500),
                      "rb": CGRect(x: 500, y: 500, width: 500, height: 500)]
        for _ in 0..<20 {
            XCTAssertEqual(neighbourSlot(from: "l", toward: .right, frames: frames), "rt")
        }
    }

    func testEachDrawerOfADisplayOpensOnItsOwn() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(2, to: browse, slot: "right.all")
        s.setOpen(browse, edge: "left", true)
        XCTAssertEqual(s.openEdges(browse), ["left"])
        XCTAssertTrue(s.isShown(1))
        XCTAssertFalse(s.isShown(2))
        // A member of the closed drawer opens that one; the open one is not touched.
        XCTAssertEqual(drawerReaction(activated: 2, on: browse, state: s, isMainLayoutWindow: false), .open(browse, edge: "right"))
        XCTAssertEqual(drawerReaction(activated: 1, on: browse, state: s, isMainLayoutWindow: false), .none)
        // The main layout closes whatever is open.
        XCTAssertEqual(drawerReaction(activated: 9, on: browse, state: s, isMainLayoutWindow: true), .close(browse))
        // A drawer without members cannot be open; emptying an open one closes it and leaves the other.
        s.setOpen(browse, edge: "right", true)
        s.remove(1)
        XCTAssertEqual(s.openEdges(browse), ["right"])
        s.setOpen(browse, edge: "left", true)
        XCTAssertEqual(s.openEdges(browse), ["right"])
        // A shown member dropped in the other drawer is shown there.
        s.send(3, to: browse, slot: "right.all")
        s.send(3, to: browse, slot: "left.top")
        XCTAssertEqual(s.openEdges(browse), ["left", "right"])
        s.setOpen(browse, false)
        XCTAssertFalse(s.isOpen(browse))
    }

    func testRemoveLastMemberDropsTheDrawer() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.setOpen(browse, true)
        XCTAssertEqual(s.remove(1), browse)
        XCTAssertFalse(s.isOpen(browse))
        XCTAssertEqual(s.allMembers, [])
        XCTAssertNil(s.remove(1))
    }

    func testAllMembersForRestore() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.send(2, to: other, slot: "left.bottom")
        XCTAssertEqual(Set(s.allMembers), [1, 2])
    }

    func testActivatingAMemberOpensItsDrawer() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        XCTAssertEqual(drawerReaction(activated: 1, on: browse, state: s, isMainLayoutWindow: false), .open(browse, edge: "left"))
    }

    func testActivationReactions() {
        var s = DrawerState()
        s.send(1, to: browse, slot: "left.top")
        s.setOpen(browse, true)
        // Back to the main layout (Brave): the drawer closes.
        XCTAssertEqual(drawerReaction(activated: 9, on: browse, state: s, isMainLayoutWindow: true), .close(browse))
        // A floating window: nothing.
        XCTAssertEqual(drawerReaction(activated: 8, on: browse, state: s, isMainLayoutWindow: false), .none)
        // A member of a drawer already open: nothing.
        XCTAssertEqual(drawerReaction(activated: 1, on: browse, state: s, isMainLayoutWindow: false), .none)
        // A main-layout window on a desktop whose drawer is closed: nothing.
        s.setOpen(browse, false)
        XCTAssertEqual(drawerReaction(activated: 9, on: browse, state: s, isMainLayoutWindow: true), .none)
    }

    func testSlotAtPoint() {
        let frames = ["top": CGRect(x: 0, y: 0, width: 100, height: 100), "bottom": CGRect(x: 0, y: 100, width: 100, height: 100)]
        XCTAssertEqual(slot(at: CGPoint(x: 50, y: 150), in: frames), "bottom")
        XCTAssertNil(slot(at: CGPoint(x: 150, y: 50), in: frames))
    }

    func testNeighbourSlot() {
        let frames = ["ide": CGRect(x: 0, y: 0, width: 600, height: 100), "web": CGRect(x: 600, y: 0, width: 400, height: 100)]
        XCTAssertEqual(neighbourSlot(from: "ide", toward: .right, frames: frames), "web")
        XCTAssertEqual(neighbourSlot(from: "web", toward: .left, frames: frames), "ide")
        XCTAssertNil(neighbourSlot(from: "ide", toward: .left, frames: frames))
    }

    func testAnArrowGoesToTheSlotBesideNotToANearerOneInAnotherDirection() {
        // A strip as wide as the display over two halves (1512 x 957): from the bottom left, the
        // centre of the strip is 610 points away and the slot on the right 756.
        let frames = ["top": CGRect(x: 0, y: 0, width: 1512, height: 300),
                      "bl": CGRect(x: 0, y: 300, width: 756, height: 657),
                      "br": CGRect(x: 756, y: 300, width: 756, height: 657)]
        XCTAssertEqual(neighbourSlot(from: "bl", toward: .right, frames: frames), "br")
        XCTAssertEqual(neighbourSlot(from: "br", toward: .left, frames: frames), "bl")
        XCTAssertEqual(neighbourSlot(from: "bl", toward: .up, frames: frames), "top")
        XCTAssertEqual(neighbourSlot(from: "br", toward: .up, frames: frames), "top")
        // Both halves are under the strip, equally near: the left one.
        XCTAssertEqual(neighbourSlot(from: "top", toward: .down, frames: frames), "bl")
        XCTAssertNil(neighbourSlot(from: "bl", toward: .left, frames: frames))
        XCTAssertNil(neighbourSlot(from: "bl", toward: .down, frames: frames))
    }

    func testASlotThatFacesNoneStillReachesTheNearestOnThatSide() {
        // Two slots in opposite corners: neither is beside nor under the other.
        let frames = ["a": CGRect(x: 0, y: 0, width: 100, height: 100), "b": CGRect(x: 200, y: 200, width: 100, height: 100)]
        XCTAssertEqual(neighbourSlot(from: "a", toward: .right, frames: frames), "b")
        XCTAssertEqual(neighbourSlot(from: "a", toward: .down, frames: frames), "b")
        XCTAssertEqual(neighbourSlot(from: "b", toward: .up, frames: frames), "a")
    }

    func testNeighbourSlotUpAndDown() {
        // A 2x2 grid (AX coordinates, y down).
        let frames = ["tl": CGRect(x: 0, y: 0, width: 100, height: 100), "tr": CGRect(x: 100, y: 0, width: 100, height: 100),
                      "bl": CGRect(x: 0, y: 100, width: 100, height: 100), "br": CGRect(x: 100, y: 100, width: 100, height: 100)]
        XCTAssertEqual(neighbourSlot(from: "tl", toward: .down, frames: frames), "bl")
        XCTAssertEqual(neighbourSlot(from: "br", toward: .up, frames: frames), "tr")
        XCTAssertNil(neighbourSlot(from: "tl", toward: .up, frames: frames))
    }

    func testVisibleRegionsSkipLayoutSlotsUnderAnOpenDrawer() {
        // Right display: Sublime 3/8 + Brave 5/8, left drawer (3/8) open in two halves.
        let layout = ["notes": CGRect(x: 0, y: 0, width: 375, height: 1000), "web": CGRect(x: 375, y: 0, width: 625, height: 1000)]
        let drawer = ["drawer:left.top": CGRect(x: 0, y: 0, width: 375, height: 500),
                      "drawer:left.bottom": CGRect(x: 0, y: 500, width: 375, height: 500)]
        let regions = visibleRegions(layout: layout, drawers: drawer, drawerZones: [CGRect(x: 0, y: 0, width: 375, height: 1000)])
        XCTAssertEqual(Set(regions.keys), ["web", "drawer:left.top", "drawer:left.bottom"])
        XCTAssertEqual(neighbourSlot(from: "drawer:left.top", toward: .down, frames: regions), "drawer:left.bottom")
        XCTAssertEqual(neighbourSlot(from: "drawer:left.bottom", toward: .right, frames: regions), "web")
    }
}
