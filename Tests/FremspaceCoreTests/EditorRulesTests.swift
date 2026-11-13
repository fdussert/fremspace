import XCTest
@testable import FremspaceCore

final class EditorRulesTests: XCTestCase {
    func testACleanFractionIsWrittenInFullSizeDigits() {
        XCTAssertEqual(fractionLabel(0.6), "3/5")
        XCTAssertEqual(fractionLabel(1.0 / 3), "1/3")
        XCTAssertEqual(fractionLabel(0.375), "3/8")
        XCTAssertEqual(fractionLabel(1), "full")
        XCTAssertEqual(fractionLabel(0.3), "30 %")
    }

    func testASlotAsHighAsTheDisplayGivesItsWidthAlone() {
        XCTAssertEqual(sizeLabel(width: 0.6, height: 1), "3/5")
        XCTAssertEqual(sizeLabel(width: 1, height: 1), "full")
        XCTAssertEqual(sizeLabel(width: 0.55, height: 1), "55 %")
    }

    func testASizeKeepsOneNotation() {
        XCTAssertEqual(sizeLabel(width: 1.0 / 3, height: 0.5), "1/3 × 1/2")
        // One side off the grid: both as percentages, the sign once.
        XCTAssertEqual(sizeLabel(width: 0.4, height: 0.55), "40 × 55 %")
        XCTAssertEqual(sizeLabel(width: 1.0 / 6, height: 0.5), "17 × 50 %")
    }

    func testASizeInWordsSaysWidthAndHeight() {
        XCTAssertEqual(sizeWords(width: 0.6, height: 1), "3/5 wide, full height")
        XCTAssertEqual(sizeWords(width: 1, height: 0.5), "full width, 1/2 high")
        XCTAssertEqual(sizeWords(width: 0.3, height: 0.45), "30 % wide, 45 % high")
    }

    func testALargeTileShowsEverything() {
        let fit = tileFit(width: 330, height: 300, apps: 1, states: 2)
        XCTAssertEqual(fit, TileFit(size: true, states: true, stateWords: true, icon: 64))
    }

    func testAnOrdinarySlotHasNoStateRow() {
        let fit = tileFit(width: 330, height: 300, apps: 1, states: 0)
        XCTAssertFalse(fit.states)
        XCTAssertFalse(fit.stateWords)
    }

    func testANarrowTileKeepsTheSymbolsAndDropsTheirWords() {
        // Two states with their words need 2 × 7 + 2 × 86 points.
        XCTAssertTrue(tileFit(width: 186, height: 200, apps: 1, states: 2).stateWords)
        let narrow = tileFit(width: 185, height: 200, apps: 1, states: 2)
        XCTAssertTrue(narrow.states)
        XCTAssertFalse(narrow.stateWords)
        // Under 90 points the size goes too.
        XCTAssertFalse(tileFit(width: 89, height: 200, apps: 1, states: 0).size)
    }

    func testTheIconNeverReachesTheTextAboveItNorTheStatesUnderIt() {
        // 80 high: 22 of title, 15 of size, 7 under, 4 clear on each side: 28 left for the icon.
        XCTAssertEqual(tileFit(width: 110, height: 80, apps: 1, states: 0).icon, 28)
        // With a state row the size line gives way first, and the icon has what is left.
        let withState = tileFit(width: 110, height: 80, apps: 1, states: 1)
        XCTAssertTrue(withState.states)
        XCTAssertFalse(withState.size)
        XCTAssertEqual(withState.icon, 25)
        // Too little left for an icon one can recognise: none.
        XCTAssertNil(tileFit(width: 110, height: 60, apps: 1, states: 1).icon)
    }

    func testSeveralIconsShareTheWidth() {
        // Three icons a fifth of their side apart in 150 - 14 points: 136 / 3.4 = 40.
        XCTAssertEqual(tileFit(width: 150, height: 300, apps: 3, states: 0).icon, 40)
        XCTAssertNil(tileFit(width: 150, height: 300, apps: 0, states: 0).icon)
    }

    func testAShortTileIsItsTitleAlone() {
        let fit = tileFit(width: 300, height: 30, apps: 1, states: 2)
        XCTAssertEqual(fit, TileFit(size: false, states: false, stateWords: false, icon: nil))
    }

    func testANewConfigurationHasADesktopPerDesktopOfTheDisplay() {
        XCTAssertEqual(starterDesktops(count: 3).map(\.label), ["Desktop 1", "Desktop 2", "Desktop 3"])
        XCTAssertTrue(starterDesktops(count: 3).allSatisfy { $0.layout == nil })
        // A display whose desktops could not be counted still gets one.
        XCTAssertEqual(starterDesktops(count: 0).map(\.label), ["Desktop 1"])
    }
}
