import XCTest
@testable import TurnstoneCore

final class WheelTests: XCTestCase {
    func testCenterAndOutsideCancelWhileSliceBoundariesRemainSelectable() {
        XCTAssertNil(WheelGeometry.selection(x: 0, y: 0, count: 4))
        XCTAssertNil(WheelGeometry.selection(x: 0, y: 141, count: 4))
        XCTAssertNotNil(WheelGeometry.selection(x: 70, y: 70, count: 4))
        XCTAssertEqual(WheelGeometry.selection(x: 0, y: 100, count: 4), 0)
        XCTAssertEqual(WheelGeometry.selection(x: 100, y: 0, count: 4), 1)
        XCTAssertEqual(WheelGeometry.selection(x: 0, y: -100, count: 4), 2)
    }
}
