import Darwin
import XCTest
@testable import CodeIsland

final class LarkBridgeManagerTests: XCTestCase {
    func testRepeatedSidecarRestartsKeepFileDescriptorCountStable() throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-lark-lifecycle-\(UUID().uuidString).py")
        try Data("import time\ntime.sleep(30)\n".utf8).write(to: scriptURL)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let manager = LarkBridgeManager(
            interpreterOverride: (executable: "/usr/bin/python3", arguments: [])
        )

        for _ in 0..<3 {
            try startAndStop(manager, scriptPath: scriptURL.path)
        }
        let baseline = openFileDescriptorCount()

        for _ in 0..<20 {
            try startAndStop(manager, scriptPath: scriptURL.path)
        }

        XCTAssertLessThanOrEqual(openFileDescriptorCount(), baseline + 2)
    }

    private func startAndStop(_ manager: LarkBridgeManager, scriptPath: String) throws {
        manager.start(scriptPath: scriptPath)
        XCTAssertTrue(waitUntil(timeout: 2) { manager.isRunning })
        manager.stop()
        XCTAssertTrue(waitUntil(timeout: 2) { !manager.isRunning })
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func openFileDescriptorCount() -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize() {
            errno = 0
            if fcntl(descriptor, F_GETFD) != -1 || errno != EBADF {
                count += 1
            }
        }
        return count
    }
}
