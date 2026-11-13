import XCTest
@testable import FremspaceCore

final class VersionTests: XCTestCase {
    func testVersionIsSemver() {
        XCTAssertNotNil(FremspaceCore.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }
}
