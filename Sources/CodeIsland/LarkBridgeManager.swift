import Foundation
import os

/// Append a line to the shared Lark debug log (same file the Python sidecar writes), so the
/// whole pipeline — Swift spawn/exit/restart + sidecar lifecycle — can be read in one place.
func larkDebugLog(_ message: String) {
    let path = "/tmp/codeisland-lark-\(getuid()).log"
    let stamp = larkLogStamp.string(from: Date())
    let line = "\(stamp) [swift] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: path) {
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        try? fh.write(contentsOf: data)
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

private let larkLogStamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// Manages the long-running Python sidecar (`codeisland-lark-bridge.py`) that owns all
/// Lark/Feishu I/O (auth, sending interactive cards, receiving `card.action.trigger` over a
/// WebSocket long connection). We keep Feishu-specific code out of Swift entirely; this class
/// only spawns the child and exchanges newline-delimited JSON over its stdin/stdout.
///
/// Threading: process I/O runs on a private queue; `onMessage` / `onExit` are delivered on the
/// main queue so `LarkNotifier` (a `@MainActor` type) can consume them directly.
final class LarkBridgeManager: @unchecked Sendable {
    private let log = Logger(subsystem: "com.codeisland", category: "lark-bridge")
    private let queue = DispatchQueue(label: "com.codeisland.lark-bridge")
    private let interpreterOverride: (executable: String, arguments: [String])?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()

    /// Delivered on the main queue.
    var onMessage: (([String: Any]) -> Void)?
    /// Delivered on the main queue with the child's exit code.
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { queue.sync { process?.isRunning ?? false } }

    init(interpreterOverride: (executable: String, arguments: [String])? = nil) {
        self.interpreterOverride = interpreterOverride
    }

    // MARK: - Lifecycle

    func start(scriptPath: String) {
        queue.async { [weak self] in self?._start(scriptPath: scriptPath) }
    }

    func stop() {
        queue.async { [weak self] in self?._stop() }
    }

    /// Send one JSON object as a single newline-terminated line to the child's stdin.
    func send(_ dict: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let handle = self.stdinHandle else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
            var line = data
            line.append(0x0A)  // '\n'
            do { try handle.write(contentsOf: line) }
            catch { self.log.error("stdin write failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Private (on queue)

    private func _start(scriptPath: String) {
        _stop()
        stdoutBuffer.removeAll(keepingCapacity: true)

        let (exe, baseArgs) = interpreterOverride ?? Self.resolvePython()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = baseArgs + [scriptPath]

        // Make a homebrew python reachable when falling back to `/usr/bin/env`.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? "/usr/bin:/bin:\(extraPaths)"
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                try? fh.close()
                return
            }
            self?.queue.async { self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                try? fh.close()
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self?.log.info("sidecar stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        }

        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            larkDebugLog("bridge: sidecar exited code=\(code)")
            self?.queue.async { [weak self] in
                guard let self, self.process === p else { return }
                let stdin = self.stdinPipe
                let stdout = self.stdoutPipe
                let stderr = self.stderrPipe
                self.stdinHandle = nil
                self.stdinPipe = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.process = nil
                Self.closePipes(stdin: stdin, stdout: stdout, stderr: stderr)
                DispatchQueue.main.async { [weak self] in self?.onExit?(code) }
            }
        }

        do {
            try proc.run()
            // Close descriptors used only by the child process. This makes EOF delivery and
            // repeated sidecar restarts deterministic.
            try? inPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            self.process = proc
            self.stdinHandle = inPipe.fileHandleForWriting
            self.stdinPipe = inPipe
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            log.info("sidecar started: \(exe, privacy: .public) \(scriptPath, privacy: .public)")
            larkDebugLog("bridge: spawned \(exe) \(scriptPath)")
        } catch {
            proc.terminationHandler = nil
            Self.closePipes(stdin: inPipe, stdout: outPipe, stderr: errPipe)
            log.error("sidecar launch failed: \(error.localizedDescription, privacy: .public)")
            larkDebugLog("bridge: launch FAILED \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in self?.onExit?(-1) }
        }
    }

    private func _stop() {
        let proc = process
        let stdin = stdinPipe
        let stdout = stdoutPipe
        let stderr = stderrPipe
        proc?.terminationHandler = nil
        stdinHandle = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        Self.closePipes(stdin: stdin, stdout: stdout, stderr: stderr)
        if let proc, proc.isRunning { ProcessRunner.terminate(proc) }
    }

    /// Accumulate stdout and emit one event per newline-delimited JSON object.
    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            DispatchQueue.main.async { [weak self] in self?.onMessage?(obj) }
        }
    }

    /// Pick an interpreter that actually has `lark_oapi` installed — the user may have
    /// `pip3 install`ed it into Homebrew's python rather than the system one. Fall back to any
    /// python3 (so the sidecar can emit `missing_dep` and the UI can prompt the install), then
    /// to `env python3` (PATH-resolved).
    private static func resolvePython() -> (exe: String, args: [String]) {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        let existing = candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
        if let withLark = existing.first(where: { probeHasLark($0) }) {
            return (withLark, [])
        }
        if let any = existing.first {
            return (any, [])
        }
        return ("/usr/bin/env", ["python3"])
    }

    /// Quick synchronous check: does `python -c "import lark_oapi"` succeed?
    private static func probeHasLark(_ python: String) -> Bool {
        ProcessRunner.runSilently(
            path: python,
            args: ["-c", "import lark_oapi"],
            timeout: 5
        )
    }

    private static func closePipes(stdin: Pipe?, stdout: Pipe?, stderr: Pipe?) {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        for pipe in [stdin, stdout, stderr].compactMap({ $0 }) {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}
