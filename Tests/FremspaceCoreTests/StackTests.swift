import XCTest
@testable import FremspaceCore

final class StackTests: XCTestCase {
    func testGoesThroughEveryWindowAndWrapsAround() {
        let stack: [UInt32] = [393, 381, 390]
        XCTAssertEqual(nextInStack(stack, after: 381), 390)
        XCTAssertEqual(nextInStack(stack, after: 390), 393)
        XCTAssertEqual(nextInStack(stack, after: 393), 381)
    }

    func testBackwardsIsTheOtherWay() {
        let stack: [UInt32] = [381, 390, 393]
        XCTAssertEqual(nextInStack(stack, after: 381, forward: false), 393)
        XCTAssertEqual(nextInStack(stack, after: 393, forward: false), 390)
    }

    func testNothingToGoToAloneOrOutsideTheStack() {
        XCTAssertNil(nextInStack([381], after: 381))
        XCTAssertNil(nextInStack([381, 390], after: 7))
    }
}
