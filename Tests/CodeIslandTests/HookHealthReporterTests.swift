import XCTest
@testable import CodeIsland

final class HookHealthReporterTests: XCTestCase {
    func testRuntimeHealthReportsMissingComponents() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let health = HookHealthReporter.runtimeHealth(
            home: tempDir.path,
            socketPath: tempDir.appendingPathComponent("missing.sock").path,
            fm: fm
        )

        XCTAssertFalse(health.bridgeExists)
        XCTAssertFalse(health.hookScriptExists)
        XCTAssertFalse(health.socketExists)
        XCTAssertEqual(Set(health.issues), Set(["bridge-missing", "hook-script-missing", "socket-not-found"]))
    }

    func testRuntimeHealthAcceptsExecutableBridgeAndHookScript() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codeIslandDir = tempDir.appendingPathComponent(".codeisland", isDirectory: true)
        try fm.createDirectory(at: codeIslandDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let bridge = codeIslandDir.appendingPathComponent("codeisland-bridge")
        let hookScript = codeIslandDir.appendingPathComponent("codeisland-hook.sh")
        let socket = tempDir.appendingPathComponent("codeisland.sock")
        try Data("bridge".utf8).write(to: bridge)
        try Data("#!/bin/sh\n".utf8).write(to: hookScript)
        try Data().write(to: socket)
        chmod(bridge.path, 0o755)
        chmod(hookScript.path, 0o755)

        let health = HookHealthReporter.runtimeHealth(
            home: tempDir.path,
            socketPath: socket.path,
            fm: fm
        )

        XCTAssertTrue(health.bridgeExists)
        XCTAssertTrue(health.bridgeExecutable)
        XCTAssertTrue(health.hookScriptExists)
        XCTAssertTrue(health.hookScriptExecutable)
        XCTAssertTrue(health.socketExists)
        XCTAssertTrue(health.issues.isEmpty)
    }
}
