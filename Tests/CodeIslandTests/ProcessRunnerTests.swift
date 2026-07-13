import Darwin
import XCTest
@testable import CodeIsland

final class ProcessRunnerTests: XCTestCase {
    func testAsyncRunnerCapturesStdoutAndStderrWithoutPipeBackpressure() async {
        let bytes = 131_072
        let result = await ProcessRunner.runAsync(
            path: "/bin/sh",
            args: ["-c", "yes o | head -c \(bytes); yes e | head -c \(bytes) >&2"],
            timeout: 5
        )

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(result.stdout.count, bytes)
        XCTAssertEqual(result.stderr.count, bytes)
    }

    func testAsyncRunnerTimesOutAndReapsChild() async {
        let started = Date()
        let result = await ProcessRunner.runAsync(
            path: "/bin/sleep",
            args: ["5"],
            timeout: 0.05
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAsyncRunnerCancellationTerminatesChild() async {
        let started = Date()
        let task = Task {
            await ProcessRunner.runAsync(
                path: "/bin/sleep",
                args: ["5"],
                timeout: 10
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.termination, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testRepeatedAsyncRunsKeepFileDescriptorCountStable() async {
        for _ in 0..<10 {
            _ = await ProcessRunner.runAsync(path: "/usr/bin/true", args: [], timeout: 2)
        }
        let baseline = openFileDescriptorCount()

        for _ in 0..<100 {
            let result = await ProcessRunner.runAsync(path: "/usr/bin/true", args: [], timeout: 2)
            XCTAssertEqual(result.termination, .exited(0))
        }

        XCTAssertLessThanOrEqual(openFileDescriptorCount(), baseline + 2)
    }

    func testRepeatedSynchronousRunsKeepFileDescriptorCountStable() {
        for _ in 0..<10 {
            _ = ProcessRunner.run(path: "/usr/bin/printf", args: ["ok"], timeout: 2)
        }
        let baseline = openFileDescriptorCount()

        for _ in 0..<100 {
            XCTAssertEqual(
                ProcessRunner.run(path: "/usr/bin/printf", args: ["ok"], timeout: 2),
                Data("ok".utf8)
            )
        }

        XCTAssertLessThanOrEqual(openFileDescriptorCount(), baseline + 2)
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
