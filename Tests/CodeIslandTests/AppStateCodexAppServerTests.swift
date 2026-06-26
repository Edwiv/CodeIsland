import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateCodexAppServerTests: XCTestCase {
    func testCodexAppServerExecutablePrefersRunningBundlePath() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("codeisland-codex-app-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("Nested/Codex.app", isDirectory: true)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let bundledExecutable = resourcesURL.appendingPathComponent("codex")
        try makeExecutable(at: bundledExecutable)

        let fallbackExecutable = tempDir.appendingPathComponent("fallback-codex")
        try makeExecutable(at: fallbackExecutable)

        let resolved = AppState.codexAppServerExecutableURL(
            runningBundleURLs: [bundleURL],
            fallbackPaths: [fallbackExecutable.path],
            fileManager: fm
        )

        XCTAssertEqual(resolved?.path, bundledExecutable.path)
    }

    func testCodexAppServerExecutableFallsBackWhenNoRunningBundlePathExists() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("codeisland-codex-app-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let fallbackExecutable = tempDir.appendingPathComponent("fallback-codex")
        try makeExecutable(at: fallbackExecutable)

        let resolved = AppState.codexAppServerExecutableURL(
            runningBundleURLs: [],
            fallbackPaths: [fallbackExecutable.path],
            fileManager: fm
        )

        XCTAssertEqual(resolved?.path, fallbackExecutable.path)
    }

    func testActiveWithApprovalFlagMapsToWaitingApproval() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval")])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testActiveWithUserInputFlagMapsToWaitingQuestion() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnUserInput")])
        ])

        XCTAssertEqual(snapshot.status, .waitingQuestion)
    }

    func testActiveWithoutFlagsMapsToRunningAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .waitingApproval
        snapshot.currentTool = "Bash"
        snapshot.toolDescription = "pending"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([])
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testIdleMapsToIdleAndClearsTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Read"
        snapshot.toolDescription = "foo.swift"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("idle")
        ])

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
    }

    func testNotLoadedAndSystemErrorMapToIdle() {
        var s1 = SessionSnapshot()
        s1.status = .running
        AppState.applyCodexThreadStatus(&s1, status: ["type": .string("notLoaded")])
        XCTAssertEqual(s1.status, .idle)

        var s2 = SessionSnapshot()
        s2.status = .running
        AppState.applyCodexThreadStatus(&s2, status: ["type": .string("systemError")])
        XCTAssertEqual(s2.status, .idle)
    }

    func testUnknownStatusTypeIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "Bash"

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("futureEnumCaseTBD")
        ])

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.currentTool, "Bash")
    }

    func testNilStatusIsNoOp() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        AppState.applyCodexThreadStatus(&snapshot, status: nil)
        XCTAssertEqual(snapshot.status, .running)
    }

    func testApprovalFlagTakesPrecedenceOverUserInputFlag() {
        // Codex can theoretically emit both flags at once; approval is strictly
        // more actionable, so we should route to .waitingApproval.
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyCodexThreadStatus(&snapshot, status: [
            "type": .string("active"),
            "activeFlags": .array([
                .string("waitingOnUserInput"),
                .string("waitingOnApproval")
            ])
        ])

        XCTAssertEqual(snapshot.status, .waitingApproval)
    }

    func testRemoteCodexTerminalDiscoveryCompletesMatchingCodexAppSession() throws {
        let appState = AppState()
        let providerSessionId = "019ef7f0-10de-7bc2-a5b6-f1edb92fe8c6"
        let codexAppSessionId = AppState.codexAppSessionPrefix + providerSessionId

        var snapshot = SessionSnapshot()
        snapshot.source = "codex"
        snapshot.termBundleId = AppState.codexAppBundleId
        snapshot.providerSessionId = providerSessionId
        snapshot.status = .running
        snapshot.cwd = "/data00/home/zhengyijie"
        appState.sessions[codexAppSessionId] = snapshot

        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": providerSessionId,
            "cwd": "/data00/home/zhengyijie",
            "_source": "codex",
            "_remote_host_id": "devbox_l4",
            "_remote_host_name": "devbox_l4",
            "_discovered": true,
            "_discovered_terminal_status": "completed",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[codexAppSessionId]?.status, .idle)
        XCTAssertEqual(appState.sessions[codexAppSessionId]?.interrupted, false)
        XCTAssertNil(appState.sessions["remote:devbox_l4:\(providerSessionId)"])
    }

    func testRemoteCodexActiveDiscoveryDoesNotDuplicateMatchingCodexAppSession() throws {
        let appState = AppState()
        let providerSessionId = "019efde1-8c99-7143-b9b1-b84a9fda8889"
        let codexAppSessionId = AppState.codexAppSessionPrefix + providerSessionId

        var snapshot = SessionSnapshot()
        snapshot.source = "codex"
        snapshot.termBundleId = AppState.codexAppBundleId
        snapshot.providerSessionId = providerSessionId
        snapshot.status = .running
        snapshot.cwd = "/opt/tiger/alpha-seed"
        appState.sessions[codexAppSessionId] = snapshot

        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": providerSessionId,
            "cwd": "/opt/tiger/alpha-seed",
            "_source": "codex",
            "_remote_host_id": "h20_debug",
            "_remote_host_name": "h20_debug",
            "_discovered": true,
            "_discovered_status": "processing",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[codexAppSessionId]?.status, .running)
        XCTAssertNil(appState.sessions["remote:h20_debug:\(providerSessionId)"])
    }

    func testRemoteCodexActiveDiscoveryCanWakeIdleMatchingCodexAppSession() throws {
        let appState = AppState()
        let providerSessionId = "019efde1-8c99-7143-b9b1-b84a9fda8889"
        let codexAppSessionId = AppState.codexAppSessionPrefix + providerSessionId

        var snapshot = SessionSnapshot()
        snapshot.source = "codex"
        snapshot.termBundleId = AppState.codexAppBundleId
        snapshot.providerSessionId = providerSessionId
        snapshot.status = .idle
        snapshot.cwd = "/opt/tiger/alpha-seed"
        appState.sessions[codexAppSessionId] = snapshot

        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": providerSessionId,
            "cwd": "/opt/tiger/alpha-seed",
            "_source": "codex",
            "_remote_host_id": "h20_debug",
            "_remote_host_name": "h20_debug",
            "_discovered": true,
            "_discovered_status": "processing",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        appState.handleEvent(event)

        XCTAssertEqual(appState.sessions[codexAppSessionId]?.status, .processing)
        XCTAssertNil(appState.sessions["remote:h20_debug:\(providerSessionId)"])
    }

    private func makeExecutable(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
