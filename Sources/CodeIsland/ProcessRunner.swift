import Darwin
import Foundation

struct ProcessExecutionResult: Equatable, Sendable {
    enum Termination: Equatable, Sendable {
        case exited(Int32)
        case launchFailed(String)
        case timedOut
        case cancelled
    }

    let stdout: Data
    let stderr: Data
    let termination: Termination

    var exitCode: Int32 {
        if case .exited(let code) = termination { return code }
        return -1
    }

    var failureDescription: String? {
        switch termination {
        case .exited(let code):
            return code == 0 ? nil : "process exited with status \(code)"
        case .launchFailed(let message):
            return message
        case .timedOut:
            return "process timed out"
        case .cancelled:
            return "process cancelled"
        }
    }
}

/// Process helpers with bounded waits and explicit pipe ownership.
///
/// `Process` keeps the `Pipe` objects assigned to standard I/O alive. Every execution must
/// therefore close the parent-side descriptors and release its handlers explicitly; relying on
/// ARC is not sufficient for a long-running app that starts subprocesses on a timer.
enum ProcessRunner {
    /// Resolve a process' controlling TTY via `ps -o tty=`.
    static func ttyForPid(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        guard let data = run(path: "/bin/ps", args: ["-o", "tty=", "-p", "\(pid)"], timeout: 5),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let tty = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "?" else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// Reference cell for the pipe drain so the closure and the calling thread share storage.
    /// Synchronization is provided by `drained` (signal happens-before wait).
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Run a command synchronously while draining stdout concurrently.
    static func run(
        path: String,
        args: [String],
        env: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = mergedEnvironment(env)

        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        defer {
            proc.terminationHandler = nil
            try? writeHandle.close()
            try? readHandle.close()
        }

        do {
            try proc.run()
        } catch {
            return nil
        }

        // The child owns its duplicated write descriptor after `run()`. Keeping this parent
        // descriptor open prevents the reader from ever observing EOF.
        try? writeHandle.close()

        let box = DataBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = readHandle.readDataToEndOfFile()
            try? readHandle.close()
            drained.signal()
        }

        let exitedInTime = waitForExit(proc, signal: exited, timeout: timeout)
        if drained.wait(timeout: .now() + 1) == .timedOut {
            // Closing the read side unblocks a drain even if Foundation failed to deliver EOF.
            try? readHandle.close()
            _ = drained.wait(timeout: .now() + 1)
            return nil
        }
        guard exitedInTime, proc.terminationStatus == 0 else { return nil }
        return box.data
    }

    /// Run a command without captured output. Useful for short helper commands that otherwise
    /// used an unbounded `waitUntilExit()` and could strand a worker thread indefinitely.
    @discardableResult
    static func runSilently(
        path: String,
        args: [String],
        env: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = mergedEnvironment(env)
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        defer { proc.terminationHandler = nil }

        do {
            try proc.run()
        } catch {
            return false
        }

        let exitedInTime = waitForExit(proc, signal: exited, timeout: timeout)
        return exitedInTime && proc.terminationStatus == 0
    }

    /// Async variant used by SSH probes and installers. Output is drained while the child runs,
    /// cancellation terminates the child, and the timeout escalates to SIGKILL if needed.
    static func runAsync(
        path: String,
        args: [String],
        env: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async -> ProcessExecutionResult {
        let execution = AsyncExecution(
            path: path,
            args: args,
            environment: mergedEnvironment(env),
            timeout: timeout
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    /// Terminate a long-lived child without allowing an ignored SIGTERM to orphan it.
    static func terminate(_ process: Process, gracePeriod: TimeInterval = 1) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, gracePeriod)) {
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private static func mergedEnvironment(_ overrides: [String: String]?) -> [String: String]? {
        guard let overrides else { return nil }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides { environment[key] = value }
        return environment
    }

    private static func waitForExit(
        _ process: Process,
        signal: DispatchSemaphore,
        timeout: TimeInterval
    ) -> Bool {
        if signal.wait(timeout: .now() + max(0, timeout)) == .success {
            return true
        }
        process.terminate()
        if signal.wait(timeout: .now() + 1) == .success {
            return false
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = signal.wait(timeout: .now() + 1)
        return false
    }

    // MARK: - Async execution state

    private final class AsyncExecution: @unchecked Sendable {
        private enum Stream {
            case stdout
            case stderr
        }

        private let path: String
        private let args: [String]
        private let environment: [String: String]?
        private let timeout: TimeInterval
        private let lock = NSLock()

        private var continuation: CheckedContinuation<ProcessExecutionResult, Never>?
        private var process: Process?
        private var stdoutPipe: Pipe?
        private var stderrPipe: Pipe?
        private var stdout = Data()
        private var stderr = Data()
        private var stdoutFinished = false
        private var stderrFinished = false
        private var processFinished = false
        private var processStatus: Int32 = -1
        private var launched = false
        private var stopReason: ProcessExecutionResult.Termination?
        private var timeoutWorkItem: DispatchWorkItem?
        private var killWorkItem: DispatchWorkItem?
        private var completed = false

        init(path: String, args: [String], environment: [String: String]?, timeout: TimeInterval) {
            self.path = path
            self.args = args
            self.environment = environment
            self.timeout = timeout
        }

        func start(continuation: CheckedContinuation<ProcessExecutionResult, Never>) {
            lock.lock()
            self.continuation = continuation
            let cancelledBeforeStart = stopReason == .cancelled
            lock.unlock()

            if cancelledBeforeStart {
                completeWithoutLaunching(.cancelled)
                return
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            proc.environment = environment
            proc.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            installHandler(on: outPipe.fileHandleForReading, stream: .stdout)
            installHandler(on: errPipe.fileHandleForReading, stream: .stderr)
            proc.terminationHandler = { [weak self] finished in
                self?.processDidExit(status: finished.terminationStatus)
            }

            lock.lock()
            process = proc
            stdoutPipe = outPipe
            stderrPipe = errPipe
            lock.unlock()

            do {
                try proc.run()
            } catch {
                completeLaunchFailure(error.localizedDescription, process: proc, stdout: outPipe, stderr: errPipe)
                return
            }

            // The child owns duplicated write descriptors. The parent must close its copies so
            // EOF is delivered once the child exits.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()

            lock.lock()
            launched = true
            let pendingStop = stopReason
            lock.unlock()

            if pendingStop != nil {
                terminateLaunchedProcess(proc)
            } else {
                scheduleTimeout()
            }
        }

        func cancel() {
            requestStop(.cancelled)
        }

        private func installHandler(on handle: FileHandle, stream: Stream) {
            handle.readabilityHandler = { [weak self] readable in
                let data = readable.availableData
                guard !data.isEmpty else {
                    readable.readabilityHandler = nil
                    try? readable.close()
                    self?.streamDidFinish(stream)
                    return
                }
                self?.append(data, to: stream)
            }
        }

        private func append(_ data: Data, to stream: Stream) {
            lock.lock()
            switch stream {
            case .stdout: stdout.append(data)
            case .stderr: stderr.append(data)
            }
            lock.unlock()
        }

        private func streamDidFinish(_ stream: Stream) {
            lock.lock()
            switch stream {
            case .stdout: stdoutFinished = true
            case .stderr: stderrFinished = true
            }
            lock.unlock()
            completeIfReady()
        }

        private func processDidExit(status: Int32) {
            lock.lock()
            processStatus = status
            processFinished = true
            lock.unlock()
            completeIfReady()
        }

        private func scheduleTimeout() {
            let item = DispatchWorkItem { [weak self] in
                self?.requestStop(.timedOut)
            }
            lock.lock()
            guard !completed, stopReason == nil else {
                lock.unlock()
                return
            }
            timeoutWorkItem = item
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, timeout),
                execute: item
            )
        }

        private func requestStop(_ reason: ProcessExecutionResult.Termination) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            if stopReason == nil { stopReason = reason }
            let proc = process
            let shouldTerminate = launched
            lock.unlock()

            if shouldTerminate, let proc {
                terminateLaunchedProcess(proc)
            }
        }

        private func terminateLaunchedProcess(_ proc: Process) {
            if proc.isRunning { proc.terminate() }

            let pid = proc.processIdentifier
            let item = DispatchWorkItem { [weak proc] in
                guard let proc, proc.isRunning else { return }
                Darwin.kill(pid, SIGKILL)
            }
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            killWorkItem?.cancel()
            killWorkItem = item
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: item)
        }

        private func completeIfReady() {
            lock.lock()
            guard !completed, processFinished, stdoutFinished, stderrFinished,
                  let continuation else {
                lock.unlock()
                return
            }

            completed = true
            let result = ProcessExecutionResult(
                stdout: stdout,
                stderr: stderr,
                termination: stopReason ?? .exited(processStatus)
            )
            let proc = process
            let timeoutItem = timeoutWorkItem
            let killItem = killWorkItem
            self.continuation = nil
            process = nil
            stdoutPipe = nil
            stderrPipe = nil
            timeoutWorkItem = nil
            killWorkItem = nil
            lock.unlock()

            timeoutItem?.cancel()
            killItem?.cancel()
            proc?.terminationHandler = nil
            continuation.resume(returning: result)
        }

        private func completeWithoutLaunching(_ reason: ProcessExecutionResult.Termination) {
            lock.lock()
            guard !completed, let continuation else {
                lock.unlock()
                return
            }
            completed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: ProcessExecutionResult(
                stdout: Data(),
                stderr: Data(),
                termination: reason
            ))
        }

        private func completeLaunchFailure(
            _ message: String,
            process proc: Process,
            stdout outPipe: Pipe,
            stderr errPipe: Pipe
        ) {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
            proc.terminationHandler = nil

            lock.lock()
            guard !completed, let continuation else {
                lock.unlock()
                return
            }
            completed = true
            let reason = stopReason ?? .launchFailed(message)
            self.continuation = nil
            process = nil
            stdoutPipe = nil
            stderrPipe = nil
            lock.unlock()

            continuation.resume(returning: ProcessExecutionResult(
                stdout: Data(),
                stderr: Data(),
                termination: reason
            ))
        }
    }
}
