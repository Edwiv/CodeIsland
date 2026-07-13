import Darwin
import XCTest
@testable import CodeIslandCore

final class CodexAppServerClientTests: XCTestCase {

    func testNaturalProcessExitCleansUpClientLifecycle() throws {
        let exited = expectation(description: "app-server process exited")
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            callbackQueue: .main
        )
        client.onExit = { status in
            XCTAssertEqual(status, 0)
            exited.fulfill()
        }

        try client.start()
        wait(for: [exited], timeout: 2)
        XCTAssertFalse(client.isRunning)
    }

    func testRepeatedStartStopKeepsFileDescriptorCountStable() throws {
        for _ in 0..<5 {
            let client = CodexAppServerClient(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                callbackQueue: .main
            )
            try client.start()
            client.stop()
        }
        let baseline = openFileDescriptorCount()

        for _ in 0..<30 {
            let client = CodexAppServerClient(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                callbackQueue: .main
            )
            try client.start()
            client.stop()
        }

        XCTAssertLessThanOrEqual(openFileDescriptorCount(), baseline + 2)
    }

    // MARK: - drainMessages

    func testDrainMessagesEmptyBuffer() {
        var buffer = Data()
        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesSingleCompleteLine() {
        var buffer = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"t-1"}}}"#.utf8)
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.kind, .notification(method: "thread/started"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesTwoLinesConsumedBothLeavesBufferEmpty() {
        var buffer = Data()
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"turn/started","params":{}}"#.utf8))
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].kind, .notification(method: "thread/started"))
        XCTAssertEqual(messages[1].kind, .notification(method: "turn/started"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainMessagesKeepsTrailingPartialLineInBuffer() {
        var buffer = Data()
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"turn/partial"#.utf8))

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(String(data: buffer, encoding: .utf8), #"{"jsonrpc":"2.0","method":"turn/partial"#)
    }

    func testDrainMessagesSkipsBlankLines() {
        var buffer = Data()
        buffer.append(0x0A)
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8))
        buffer.append(0x0A)

        let messages = CodexAppServerClient.drainMessages(buffer: &buffer)
        XCTAssertEqual(messages.count, 1)
    }

    // MARK: - parseMessage kind detection

    func testParseMessageClassifiesRequest() {
        let data = Data(#"{"jsonrpc":"2.0","id":42,"method":"thread/start","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .request(method: "thread/start", id: .int(42)))
    }

    func testParseMessageClassifiesNotification() {
        let data = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .notification(method: "thread/started"))
    }

    func testParseMessageClassifiesResponse() {
        let data = Data(#"{"id":7,"result":{"ok":true}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .response(id: .int(7)))
    }

    func testParseMessageClassifiesError() {
        let data = Data(#"{"id":7,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .error(id: .int(7), code: -32601, message: "Method not found"))
    }

    func testParseMessageHandlesStringId() {
        let data = Data(#"{"jsonrpc":"2.0","id":"abc-1","method":"thread/start","params":{}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .request(method: "thread/start", id: .string("abc-1")))
    }

    func testParseMessageRejectsInvalidJSON() {
        let data = Data("not json".utf8)
        XCTAssertNil(CodexAppServerClient.parseMessage(data))
    }

    /// Codex surfaces plan-mode prompts as a server->client *request* (has an id),
    /// not a notification. It must classify as `.request` so AppState can answer it. (#209)
    func testParseMessageClassifiesRequestUserInput() {
        let data = Data(#"{"jsonrpc":"2.0","id":"r-1","method":"item/tool/requestUserInput","params":{"threadId":"t-1","turnId":"u-1","itemId":"i-1","questions":[{"id":"q1","header":"Plan","question":"Pick","isOther":false,"isSecret":false,"options":[{"label":"A","description":"d"}]}]}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        XCTAssertEqual(msg?.kind, .request(method: "item/tool/requestUserInput", id: .string("r-1")))
        let questions = msg?.raw["params"]?.asObject?["questions"]
        if case .array(let arr)? = questions {
            XCTAssertEqual(arr.first?.asObject?["id"]?.asString, "q1")
        } else {
            XCTFail("expected questions array")
        }
    }

    func testParseMessagePreservesRawParams() {
        let data = Data(#"{"jsonrpc":"2.0","method":"thread/started","params":{"thread":{"id":"t-1","preview":"hi"}}}"#.utf8)
        let msg = CodexAppServerClient.parseMessage(data)
        let params = msg?.raw["params"]?.asObject
        let thread = params?["thread"]?.asObject
        XCTAssertEqual(thread?["id"]?.asString, "t-1")
        XCTAssertEqual(thread?["preview"]?.asString, "hi")
    }

    // MARK: - AnyCodableLike

    func testAnyCodableLikeRoundTripsPrimitives() {
        XCTAssertEqual(AnyCodableLike.from(nil), .null)
        XCTAssertEqual(AnyCodableLike.from(NSNull()), .null)
        XCTAssertEqual(AnyCodableLike.from(true), .bool(true))
        XCTAssertEqual(AnyCodableLike.from(42), .int(42))
        XCTAssertEqual(AnyCodableLike.from("hi"), .string("hi"))

        // Floats end up as .double (bridged through NSNumber's float-check logic).
        if case .double(let value) = AnyCodableLike.from(3.14) {
            XCTAssertEqual(value, 3.14, accuracy: 0.0001)
        } else {
            XCTFail("expected .double for 3.14")
        }
    }

    func testAnyCodableLikeHandlesNestedObject() {
        let obj: [String: Any] = [
            "k1": "v1",
            "k2": 2,
            "k3": [1, 2, 3],
            "k4": ["inner": true]
        ]
        let wrapped = AnyCodableLike.from(obj)
        let dict = wrapped.asObject
        XCTAssertEqual(dict?["k1"]?.asString, "v1")
        XCTAssertEqual(dict?["k2"], .int(2))
        if case .array(let a) = dict?["k3"] ?? .null {
            XCTAssertEqual(a, [.int(1), .int(2), .int(3)])
        } else {
            XCTFail("expected array for k3")
        }
        XCTAssertEqual(dict?["k4"]?.asObject?["inner"]?.asBool, true)
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
