import XCTest
@testable import CodeIsland

@MainActor
final class RemoteManagerTests: XCTestCase {
    func testReconnectDelayFollowsExpectedBackoff() {
        // Faster reconnect backoff table (R3): [1, 2, 4, 8, 15, 30].
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 1), 1)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 2), 2)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 3), 4)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 4), 8)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 5), 15)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 6), 30)
    }

    func testReconnectDelayClampsBeyondTable() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 7), 30)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 100), 30)
    }

    func testReconnectDelayNeverReturnsLessThanFirstStepForBogusInput() {
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: 0), 1)
        XCTAssertEqual(RemoteManager.reconnectDelay(attempt: -1), 1)
    }
}
