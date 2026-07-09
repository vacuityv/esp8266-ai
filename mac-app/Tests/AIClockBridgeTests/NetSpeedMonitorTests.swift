import XCTest
@testable import AIClockBridge

final class NetSpeedMonitorTests: XCTestCase {
    func testCounterDecreaseIsDiscarded() {
        XCTAssertNil(NetSpeedMonitor.counterDelta(current: 10, previous: 5_000_000_000))
    }

    func testCounterIncreaseReturnsDifference() {
        XCTAssertEqual(NetSpeedMonitor.counterDelta(current: 250, previous: 100), 150)
    }
}
