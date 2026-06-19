import XCTest
@testable import CodeIslandCore

/// Connect-time discovery replays a quiet `SessionStart` (marked `_discovered`) for each
/// pre-existing remote session. Regression coverage for #3: a brand-new discovered session
/// must run the SessionStart body so the scanned last exchange shows up as chat rows, while a
/// replay for a session we already track must NOT reset that live session.
final class RemoteDiscoveryReplayTests: XCTestCase {

    func testDiscoveredSessionPopulatesConversationAndMetadata() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-1",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
            "_remote_host_name": "devbox_14",
            "_discovered": true,
            "session_title": "最近 Claude 有什么更新",
            "last_user_message": "最近 Claude 有什么更新",
            "last_assistant_message": "这是最近的更新摘要……",
            "model": "orange_o48",
            "input_tokens": 51200,
        ])

        var sessions: [String: SessionSnapshot] = [:]
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)
        // HookEvent prefixes remote sessions as remote:<host>:<rawId> (Models.swift).
        let key = "remote:devbox_14:remote-1"
        let session = sessions[key]

        // The conversation must attach as chat rows (this is what used to be dropped).
        XCTAssertEqual(session?.recentMessages.count, 2)
        XCTAssertEqual(session?.recentMessages.first?.isUser, true)
        XCTAssertEqual(session?.recentMessages.first?.text, "最近 Claude 有什么更新")
        XCTAssertEqual(session?.recentMessages.last?.isUser, false)
        XCTAssertEqual(session?.lastUserPrompt, "最近 Claude 有什么更新")

        // Metadata from the scan survives (no reset wiping it).
        XCTAssertEqual(session?.model, "orange_o48")
        XCTAssertEqual(session?.shortModelName, "orange_o48")
        XCTAssertEqual(session?.lastInputTokens, 51200)
        XCTAssertEqual(session?.remoteHostId, "devbox_14")
        XCTAssertTrue(session?.isRemote == true)

        // Discovery is silent: it must not play a sound or steal the active selection.
        XCTAssertFalse(effects.contains(.playSound("SessionStart")))
        XCTAssertFalse(effects.contains(.setActiveSession(sessionId: key)))
    }

    func testDiscoveredSessionWithOnlyTitleSurfacesTitleAsUserMessage() {
        // Scan found only a summary line (real user turns were meta/noise) — the remote row
        // should still render a ">" prompt line rather than title-only.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-2",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
            "_remote_host_name": "devbox_14",
            "_discovered": true,
            "session_title": "resume from 069a",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)
        let session = sessions["remote:devbox_14:remote-2"]

        XCTAssertEqual(session?.recentMessages.count, 1)
        XCTAssertEqual(session?.recentMessages.first?.isUser, true)
        XCTAssertEqual(session?.recentMessages.first?.text, "resume from 069a")
        XCTAssertEqual(session?.lastUserPrompt, "resume from 069a")
    }

    func testDiscoveredReplayDoesNotResetTrackedLiveSession() {
        var sessions: [String: SessionSnapshot] = [:]
        let key = "remote:devbox_14:remote-3"

        // A live session begins and does real work.
        _ = reduceEvent(sessions: &sessions, event: makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-3",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
        ]), maxHistory: 100)
        _ = reduceEvent(sessions: &sessions, event: makeEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "remote-3",
            "_remote_host_id": "devbox_14",
            "prompt": "live work in progress",
        ]), maxHistory: 100)

        XCTAssertEqual(sessions[key]?.recentMessages.last?.text, "live work in progress")
        XCTAssertEqual(sessions[key]?.status, .processing)

        // A discovery replay for the same (already-tracked) session must not wipe live state.
        _ = reduceEvent(sessions: &sessions, event: makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-3",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
            "_discovered": true,
            "session_title": "stale scanned title",
            "last_user_message": "stale scanned prompt",
        ]), maxHistory: 100)

        XCTAssertEqual(sessions[key]?.recentMessages.last?.text, "live work in progress")
        XCTAssertEqual(sessions[key]?.lastUserPrompt, "live work in progress")
        XCTAssertEqual(sessions[key]?.status, .processing)
    }

    func testDiscoveredSessionPopulatesEvenWhenCallerPreCreatedPlaceholder() {
        // Mirrors AppState.handleEvent, which creates an empty placeholder BEFORE calling the
        // reducer. The reducer must therefore trust `alreadyTracked: false` (not
        // `sessions[id] != nil`) to know the session is new and run the body. Regression guard
        // for the two-create-sites bug where production always saw the session as pre-existing
        // and skipped every discovered session's conversation (#3).
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-4",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
            "_remote_host_name": "devbox_14",
            "_discovered": true,
            "session_title": "标题",
            "last_user_message": "用户的问题",
            "last_assistant_message": "助手的回复",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        let key = "remote:devbox_14:remote-4"
        sessions[key] = SessionSnapshot()   // caller's placeholder, exactly like handleEvent

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100, alreadyTracked: false)

        XCTAssertEqual(sessions[key]?.recentMessages.count, 2)
        XCTAssertEqual(sessions[key]?.recentMessages.first?.text, "用户的问题")
        XCTAssertEqual(sessions[key]?.recentMessages.last?.text, "助手的回复")
    }

    // MARK: - Inferred live status (#3 follow-up)

    func testDiscoveredActiveSessionShowsProcessing() {
        // A session whose transcript was touched within the discovery active-window is replayed
        // with `_discovered_status`, so a session already mid-task before we connected shows as
        // active immediately (it has no UserPromptSubmit/PreToolUse to replay).
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-active",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
            "_remote_host_name": "devbox_14",
            "_discovered": true,
            "_discovered_status": "processing",
            "session_title": "running task",
            "last_user_message": "do the thing",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)
        let key = "remote:devbox_14:remote-active"

        XCTAssertEqual(sessions[key]?.status, .processing)
        // Inferred status must not break discovery's silence.
        XCTAssertFalse(effects.contains(.playSound("SessionStart")))
        XCTAssertFalse(effects.contains(.setActiveSession(sessionId: key)))
    }

    func testDiscoveredStatusHintDoesNotOverrideTrackedLiveSession() {
        var sessions: [String: SessionSnapshot] = [:]
        let key = "remote:devbox_14:remote-5"

        // A live session is mid-turn (.processing).
        _ = reduceEvent(sessions: &sessions, event: makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-5",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
        ]), maxHistory: 100)
        _ = reduceEvent(sessions: &sessions, event: makeEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "remote-5",
            "_remote_host_id": "devbox_14",
            "prompt": "live work",
        ]), maxHistory: 100)
        XCTAssertEqual(sessions[key]?.status, .processing)

        // A discovery replay carrying a status hint for the same tracked session must be ignored
        // (it breaks out early on `isDiscovered && sessionExisted`).
        _ = reduceEvent(sessions: &sessions, event: makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-5",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
            "_discovered": true,
            "_discovered_status": "running",
        ]), maxHistory: 100)

        XCTAssertEqual(sessions[key]?.status, .processing)
    }

    func testDiscoveredWithoutStatusHintStaysIdle() {
        // A stale (outside the active-window) discovered session carries no hint and stays idle.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "remote-6",
            "cwd": "/home/dev/project",
            "_source": "claude",
            "_remote_host_id": "devbox_14",
            "_discovered": true,
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["remote:devbox_14:remote-6"]?.status, .idle)
    }

    // MARK: - Helpers

    private func makeEvent(_ payload: [String: Any]) -> HookEvent {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return HookEvent(from: data)!
    }
}
