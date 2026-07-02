import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class SessionSuppressionRulesTests: XCTestCase {
    func testEmptyPatternsNeverMatch() throws {
        let event = try makeEvent(prompt: "Supervisor execution contract")

        XCTAssertFalse(SessionSuppressionRules.eventMatches(event, patternsRaw: ""))
        XCTAssertFalse(SessionSuppressionRules.eventMatches(event, patternsRaw: " , \n "))
    }

    func testMatchesSupervisorPromptText() throws {
        let event = try makeEvent(prompt: "**Supervisor execution contract（自动化执行约束）**")

        XCTAssertTrue(SessionSuppressionRules.eventMatches(event, patternsRaw: "Supervisor execution contract"))
    }

    func testMatchesNestedPayloadTextCaseInsensitively() throws {
        let event = try makeEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "_source": "claude",
            "payload": [
                "message": "There's an issue with the selected model (orange_o48[1m])."
            ],
        ])

        XCTAssertTrue(SessionSuppressionRules.eventMatches(event, patternsRaw: "ORANGE_O48[1m]"))
    }

    func testCommaAndNewlineSeparatedPatterns() {
        XCTAssertTrue(SessionSuppressionRules.fieldsMatch(
            ["cwd=/tmp/run", "model=orange_o48[1m]"],
            patternsRaw: "claude-mem\norange_o48[1m]"
        ))
        XCTAssertTrue(SessionSuppressionRules.fieldsMatch(
            ["prompt=background automation"],
            patternsRaw: ".cache/agents, background automation"
        ))
    }

    func testMatchesPersistedSessionPrompt() {
        let now = Date()
        let persisted = PersistedSession(
            sessionId: "s1",
            cwd: "/tmp/run",
            source: "claude",
            model: "orange_o48[1m]",
            sessionTitle: nil,
            sessionTitleSource: nil,
            providerSessionId: nil,
            lastUserPrompt: "**Supervisor execution contract（自动化执行约束）**",
            lastAssistantMessage: nil,
            termApp: nil,
            itermSessionId: nil,
            ttyPath: nil,
            kittyWindowId: nil,
            tmuxPane: nil,
            tmuxClientTty: nil,
            tmuxEnv: nil,
            termBundleId: nil,
            cmuxSurfaceId: nil,
            cmuxWorkspaceId: nil,
            zellijPaneId: nil,
            zellijSessionName: nil,
            weztermPaneId: nil,
            cliPid: nil,
            cliStartTime: nil,
            startTime: now,
            lastActivity: now
        )

        XCTAssertTrue(SessionSuppressionRules.persistedSessionMatches(
            persisted,
            patternsRaw: "Supervisor execution contract"
        ))
        XCTAssertTrue(SessionSuppressionRules.persistedSessionMatches(
            persisted,
            patternsRaw: "ORANGE_O48[1m]"
        ))
    }

    private func makeEvent(prompt: String) throws -> HookEvent {
        try makeEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "_source": "claude",
            "prompt": prompt,
        ])
    }

    private func makeEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
