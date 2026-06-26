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

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
