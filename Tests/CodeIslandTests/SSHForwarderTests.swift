import XCTest
@testable import CodeIsland

@MainActor
final class SSHForwarderTests: XCTestCase {

    // MARK: - cleanupArguments

    func testCleanupArgumentsBasic() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertEqual(args, [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "alice@192.168.1.10", "rm", "-f", "/tmp/codeisland-501.sock",
        ])
    }

    func testCleanupArgumentsIncludesIdentityFile() {
        let host = RemoteHost(
            name: "test",
            host: "192.168.1.10",
            user: "alice",
            identityFile: "~/.ssh/id_ed25519"
        )
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("~/.ssh/id_ed25519"))
        // -i must appear before the target
        let iIndex = args.firstIndex(of: "-i")!
        let targetIndex = args.firstIndex(of: "alice@192.168.1.10")!
        XCTAssertLessThan(iIndex, targetIndex)
    }

    func testCleanupArgumentsIncludesPort() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice", port: 2222)
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
    }

    func testCleanupArgumentsIncludesPortAndIdentity() {
        let host = RemoteHost(
            name: "test",
            host: "example.com",
            user: "bob",
            port: 2222,
            identityFile: "/Users/bob/.ssh/id_rsa"
        )
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-1000.sock")

        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/Users/bob/.ssh/id_rsa"))
        // Last three elements are always: target, "rm", "-f", socketPath
        let suffix = args.suffix(4)
        XCTAssertEqual(Array(suffix), ["bob@example.com", "rm", "-f", "/tmp/codeisland-1000.sock"])
    }

    func testCleanupArgumentsTrimsIdentityWhitespace() {
        let host = RemoteHost(
            name: "test",
            host: "192.168.1.10",
            user: "alice",
            identityFile: "  ~/.ssh/id_ed25519  "
        )
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        // Should include -i with trimmed value
        let iIndex = args.firstIndex(of: "-i")!
        XCTAssertEqual(args[iIndex + 1], "~/.ssh/id_ed25519")
    }

    func testCleanupArgumentsEmptyIdentityOmitted() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice", identityFile: "")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertFalse(args.contains("-i"))
    }

    func testCleanupArgumentsEmptyPortOmitted() {
        let host = RemoteHost(name: "test", host: "192.168.1.10", user: "alice")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-501.sock")

        XCTAssertFalse(args.contains("-p"))
    }

    func testCleanupArgumentsAlwaysIncludesRm() {
        let host = RemoteHost(name: "test", host: "10.0.0.1", user: "root")
        let socketPath = "/tmp/codeisland-0.sock"
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: socketPath)

        // Must contain: rm -f <socketPath>
        let rmIndex = args.firstIndex(of: "rm")!
        XCTAssertEqual(args[rmIndex + 1], "-f")
        XCTAssertEqual(args[rmIndex + 2], socketPath)
    }

    func testCleanupArgumentsBatchModeAlwaysOn() {
        let host = RemoteHost(name: "test", host: "10.0.0.1", user: "root")
        let args = SSHForwarder.cleanupArguments(host: host, remoteSocketPath: "/tmp/codeisland-0.sock")

        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=5"))
    }

    // MARK: - tunnelArguments

    func testTunnelArgumentsUseDedicatedConnectionAndFastKeepalive() {
        let host = RemoteHost(name: "test", host: "devbox")
        let args = SSHForwarder.tunnelArguments(
            host: host,
            localSocketPath: "/tmp/codeisland-501.sock",
            remoteSocketPath: "/tmp/codeisland-1000.sock"
        )

        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("ConnectionAttempts=1"))
        XCTAssertTrue(args.contains("TCPKeepAlive=yes"))
        XCTAssertTrue(args.contains("ServerAliveInterval=10"))
        XCTAssertTrue(args.contains("ServerAliveCountMax=2"))
        XCTAssertTrue(args.contains("ControlMaster=no"))
        XCTAssertTrue(args.contains("ControlPath=none"))
        XCTAssertEqual(Array(args.suffix(3)), ["-R", "/tmp/codeisland-1000.sock:/tmp/codeisland-501.sock", "devbox"])
    }

    func testSSHEnvironmentUsesConfiguredAuthSocket() {
        let host = RemoteHost(
            name: "test",
            host: "devbox",
            authSocket: "  /tmp/agent.sock  "
        )

        let environment = SSHForwarder.environment(host: host, base: ["PATH": "/usr/bin"])

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/tmp/agent.sock")
    }
}
