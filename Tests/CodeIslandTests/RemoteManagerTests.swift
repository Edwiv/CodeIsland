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

    func testHookInstallationRetriesTransientSSHFailures() {
        XCTAssertEqual(RemoteManager.hookInstallRetryDelaysSeconds, [2, 5])
    }

    func testForwardProbeScriptChecksTheReverseForwardAndResponse() {
        let script = RemoteInstaller.forwardProbeScript(remoteSocketPath: "/tmp/codeisland-1000.sock")

        XCTAssertTrue(script.contains("socket_path = \"/tmp/codeisland-1000.sock\""))
        XCTAssertTrue(script.contains("sock.connect(socket_path)"))
        XCTAssertTrue(script.contains(#"request = b'{"_codeisland_health_probe":true}'"#))
        XCTAssertTrue(script.contains(#"expected = b'{"ok":true}'"#))
        XCTAssertTrue(script.contains("sock.shutdown(socket.SHUT_WR)"))
    }

    func testHookServerHealthProbeProtocolMatchesRemoteProbe() {
        XCTAssertEqual(HookServer.healthProbeRequest, Data(#"{"_codeisland_health_probe":true}"#.utf8))
        XCTAssertEqual(HookServer.healthProbeResponse, Data(#"{"ok":true}"#.utf8))
    }

    func testRemoteCommandsAreBoundedAndRespectConfiguredControlMaster() {
        let args = RemoteInstaller.sshArguments(host: RemoteHost(name: "test", host: "devbox"))

        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=8"))
        XCTAssertTrue(args.contains("ConnectionAttempts=1"))
        XCTAssertTrue(args.contains("TCPKeepAlive=yes"))
        XCTAssertTrue(args.contains("ServerAliveInterval=15"))
        XCTAssertTrue(args.contains("ServerAliveCountMax=2"))
        XCTAssertFalse(args.contains("ControlMaster=no"))
        XCTAssertFalse(args.contains("ControlPath=none"))
        XCTAssertEqual(args.last, "devbox")
    }

    func testSSHCommandGateSerializesConcurrentOperations() async {
        let gate = SSHCommandGate(limit: 1)
        let probe = SSHConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(10))
                    await probe.leave()
                    await gate.release()
                }
            }
        }

        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 1)
    }
}

private actor SSHConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}
