import XCTest

final class RemoteHookCodexScannerTests: XCTestCase {
    func testCodexScannerTreatsToolActivityAfterTaskCompleteAsLive() throws {
        let jsonl = [
            jsonLine(["type": "session_meta", "payload": ["cwd": "/opt/tiger/mariana", "model": "gproxy"]]),
            jsonLine(["type": "event_msg", "payload": ["type": "user_message", "message": "keep working"]]),
            jsonLine(["type": "event_msg", "payload": ["type": "task_complete"]]),
            jsonLine(["type": "response_item", "payload": ["type": "function_call", "name": "shell"]]),
        ].joined(separator: "\n") + "\n"

        let scan = try scanCodexJSONL(jsonl)

        XCTAssertNil(scan["terminal_status"])
        XCTAssertEqual(scan["cwd"] as? String, "/opt/tiger/mariana")
        XCTAssertEqual(scan["model"] as? String, "gproxy")
        XCTAssertEqual(scan["last_user_message"] as? String, "keep working")
    }

    func testCodexScannerKeepsCompletedWhenNoPostTerminalActivityExists() throws {
        let jsonl = [
            jsonLine(["type": "session_meta", "payload": ["cwd": "/opt/tiger/mariana", "model": "gproxy"]]),
            jsonLine(["type": "event_msg", "payload": ["type": "user_message", "message": "finish this"]]),
            jsonLine(["type": "event_msg", "payload": ["type": "task_complete"]]),
        ].joined(separator: "\n") + "\n"

        let scan = try scanCodexJSONL(jsonl)

        XCTAssertEqual(scan["terminal_status"] as? String, "completed")
        XCTAssertEqual(scan["last_user_message"] as? String, "finish this")
    }

    func testRemoteHookExtractsLiveClaudeResumeIds() throws {
        let output = try runPythonModuleSnippet("""
        commands = [
            "/home/me/.nvm/bin/claude --resume live-claude --permission-mode default",
            "/opt/ccbridge/claude --output-format stream-json --resume bridge-session",
            "/usr/bin/python3 ~/.codeisland/codeisland-remote-hook.py --discover",
            "/opt/codebuddy/bin/codebuddy --resume codebuddy-live",
        ]
        ids = module._live_session_ids_from_commands(commands)
        print(json.dumps({key: sorted(value) for key, value in ids.items()}, ensure_ascii=False))
        """)
        let data = Data(output.utf8)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])

        XCTAssertEqual(parsed["claude"], ["bridge-session", "live-claude"])
        XCTAssertEqual(parsed["codebuddy"], ["codebuddy-live"])
    }

    func testRemoteHookExtractsYoungLiveSessionAges() throws {
        let output = try runPythonModuleSnippet("""
        lines = [
            "42 /home/me/.nvm/bin/claude --resume live-claude --permission-mode default",
            "86401 /opt/ccbridge/claude --output-format stream-json --resume old-bridge-session",
            "12 /opt/codebuddy/bin/codebuddy --resume codebuddy-live",
            "5 /usr/bin/python3 ~/.codeisland/codeisland-remote-hook.py --discover",
            "bad-age /home/me/.nvm/bin/claude --resume ignored",
        ]
        ages = module._live_session_ages_from_ps_lines(lines)
        print(json.dumps(ages, ensure_ascii=False, sort_keys=True))
        """)
        let data = Data(output.utf8)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Int]])

        XCTAssertEqual(parsed["claude"], ["live-claude": 42, "old-bridge-session": 86_401])
        XCTAssertEqual(parsed["codebuddy"], ["codebuddy-live": 12])
    }

    func testRemoteHookDiscoverySkipsStaleClaudeAndSubagents() throws {
        let output = try runPythonModuleSnippet("""
        now = 1000.0
        active_window = 90
        max_live_age = 86400
        live = {"claude": {"live-session": 3600, "old-live-session": 86401}, "codebuddy": {}}
        cases = {
            "stale": module._should_replay_discovered("claude", "/home/me/.claude/projects/p/stale.jsonl", "stale", 800.0, now, live, active_window, max_live_age),
            "recent": module._should_replay_discovered("claude", "/home/me/.claude/projects/p/recent.jsonl", "recent", 950.0, now, live, active_window, max_live_age),
            "young_live": module._should_replay_discovered("claude", "/home/me/.claude/projects/p/live-session.jsonl", "live-session", 100.0, now, live, active_window, max_live_age),
            "old_live": module._should_replay_discovered("claude", "/home/me/.claude/projects/p/old-live-session.jsonl", "old-live-session", 100.0, now, live, active_window, max_live_age),
            "subagent": module._should_replay_discovered("claude", "/home/me/.claude/projects/p/live/subagents/agent-a.jsonl", "agent-a", 995.0, now, live, active_window, max_live_age),
            "codex": module._should_replay_discovered("codex", "/home/me/.codex/sessions/x.jsonl", "codex-id", 100.0, now, live, active_window, max_live_age),
        }
        print(json.dumps(cases, ensure_ascii=False, sort_keys=True))
        """)
        let data = Data(output.utf8)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])

        XCTAssertEqual(parsed["stale"], false)
        XCTAssertEqual(parsed["recent"], true)
        XCTAssertEqual(parsed["young_live"], true)
        XCTAssertEqual(parsed["old_live"], false)
        XCTAssertEqual(parsed["subagent"], false)
        XCTAssertEqual(parsed["codex"], true)
    }

    private func scanCodexJSONL(_ contents: String) throws -> [String: Any] {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CodeIslandRemoteHookCodexScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let transcript = tempDir.appendingPathComponent("rollout-2026-06-26T12-00-00-019ef99c-9947-7f32-98ae-c40070a1c5e0.jsonl")
        try contents.write(to: transcript, atomically: true, encoding: .utf8)

        let script = packageRoot()
            .appendingPathComponent("Sources/CodeIsland/Resources/codeisland-remote-hook.py")
        let output = try runPython(script: script, transcript: transcript)
        let data = Data(output.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runPython(script: URL, transcript: URL) throws -> String {
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [
            "-c",
            """
            import importlib.util
            import json
            import sys
            spec = importlib.util.spec_from_file_location("remote_hook", sys.argv[1])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            print(json.dumps(module._scan_codex_jsonl(sys.argv[2]), ensure_ascii=False))
            """,
            script.path,
            transcript.path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        python.standardOutput = stdout
        python.standardError = stderr

        try python.run()
        python.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if python.terminationStatus != 0 {
            throw XCTSkip("python3 failed with status \(python.terminationStatus): \(err)")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runPythonModuleSnippet(_ snippet: String) throws -> String {
        let script = packageRoot()
            .appendingPathComponent("Sources/CodeIsland/Resources/codeisland-remote-hook.py")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [
            "-c",
            """
            import importlib.util
            import json
            import sys
            spec = importlib.util.spec_from_file_location("remote_hook", sys.argv[1])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            \(snippet)
            """,
            script.path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        python.standardOutput = stdout
        python.standardError = stderr

        try python.run()
        python.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if python.terminationStatus != 0 {
            throw XCTSkip("python3 failed with status \(python.terminationStatus): \(err)")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
