import XCTest
@testable import CodeIsland
import CodeIslandCore

final class AppStateRemoteCleanupTests: XCTestCase {
    func testStaleRemoteProcessingSessionExpiresAfterUserTimeout() {
        let now = Date()
        var session = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-121 * 60))

        XCTAssertTrue(AppState.shouldRemoveStaleRemoteSession(session, now: now, timeoutMinutes: 120))

        session.lastActivity = now.addingTimeInterval(-119 * 60)
        XCTAssertFalse(AppState.shouldRemoveStaleRemoteSession(session, now: now, timeoutMinutes: 120))
    }

    func testRemoteWaitingSessionsDoNotExpireByStaleProcessingRule() {
        let now = Date()

        XCTAssertFalse(AppState.shouldRemoveStaleRemoteSession(
            remoteSession(status: .waitingApproval, lastActivity: now.addingTimeInterval(-6 * 60 * 60)),
            now: now,
            timeoutMinutes: 120
        ))
        XCTAssertFalse(AppState.shouldRemoveStaleRemoteSession(
            remoteSession(status: .waitingQuestion, lastActivity: now.addingTimeInterval(-6 * 60 * 60)),
            now: now,
            timeoutMinutes: 120
        ))
    }

    func testLocalAndIdleSessionsDoNotUseRemoteStaleRule() {
        let now = Date()
        var local = SessionSnapshot()
        local.status = .processing
        local.lastActivity = now.addingTimeInterval(-6 * 60 * 60)

        XCTAssertFalse(AppState.shouldRemoveStaleRemoteSession(local, now: now, timeoutMinutes: 120))
        XCTAssertFalse(AppState.shouldRemoveStaleRemoteSession(
            remoteSession(status: .idle, lastActivity: now.addingTimeInterval(-6 * 60 * 60)),
            now: now,
            timeoutMinutes: 120
        ))
    }

    func testZeroTimeoutDisablesRemoteStaleRule() {
        let now = Date()
        XCTAssertFalse(AppState.shouldRemoveStaleRemoteSession(
            remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-6 * 60 * 60)),
            now: now,
            timeoutMinutes: 0
        ))
    }

    func testRemoteSnapshotRemovesMissingNonWaitingSessionsForSameHostAndSource() {
        let now = Date()
        var missing = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-300), source: "claude")
        missing.providerSessionId = "missing"

        var confirmed = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-300), source: "claude")
        confirmed.providerSessionId = "confirmed"

        var waiting = remoteSession(status: .waitingQuestion, lastActivity: now.addingTimeInterval(-300), source: "claude")
        waiting.providerSessionId = "waiting"

        var otherHost = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-300), source: "claude")
        otherHost.remoteHostId = "devbox_l4"
        otherHost.providerSessionId = "missing"

        let removeIds = AppState.remoteSessionIdsToRemoveAfterSnapshot(
            sessions: [
                "remote:devbox_t4:missing": missing,
                "remote:devbox_t4:confirmed": confirmed,
                "remote:devbox_t4:waiting": waiting,
                "remote:devbox_l4:missing": otherHost,
            ],
            hostId: "devbox_t4",
            snapshotSources: ["claude"],
            confirmedProviderSessionIdsBySource: ["claude": ["confirmed"]],
            observedAt: now
        )

        XCTAssertEqual(removeIds, ["remote:devbox_t4:missing"])
    }

    func testRemoteSnapshotDoesNotRemoveSourcesOutsideSnapshot() {
        let now = Date()
        var custom = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-300), source: "hermes")
        custom.providerSessionId = "custom"

        let removeIds = AppState.remoteSessionIdsToRemoveAfterSnapshot(
            sessions: ["remote:devbox_t4:custom": custom],
            hostId: "devbox_t4",
            snapshotSources: ["claude", "codex"],
            confirmedProviderSessionIdsBySource: [:],
            observedAt: now
        )

        XCTAssertTrue(removeIds.isEmpty)
    }

    func testRemoteSnapshotDoesNotRemoveSessionsNewerThanSnapshot() {
        let now = Date()
        var session = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(1), source: "claude")
        session.providerSessionId = "newer"

        let removeIds = AppState.remoteSessionIdsToRemoveAfterSnapshot(
            sessions: ["remote:devbox_t4:newer": session],
            hostId: "devbox_t4",
            snapshotSources: ["claude"],
            confirmedProviderSessionIdsBySource: [:],
            observedAt: now
        )

        XCTAssertTrue(removeIds.isEmpty)
    }

    @MainActor
    func testRemoteSnapshotEventRemovesStaleSessionWithoutCreatingPlaceholder() throws {
        let appState = AppState()
        let now = Date()

        var stale = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-300), source: "claude")
        stale.providerSessionId = "stale"
        appState.sessions["remote:devbox_t4:stale"] = stale

        var kept = remoteSession(status: .processing, lastActivity: now.addingTimeInterval(-300), source: "claude")
        kept.providerSessionId = "kept"
        appState.sessions["remote:devbox_t4:kept"] = kept

        let payload: [String: Any] = [
            "hook_event_name": "RemoteSessionSnapshot",
            "_remote_host_id": "devbox_t4",
            "_remote_host_name": "devbox_t4",
            "_snapshot_complete": true,
            "_snapshot_observed_at": now.timeIntervalSince1970,
            "_snapshot_sources": ["claude", "codex"],
            "sessions": [
                ["source": "claude", "session_id": "kept"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        appState.handleEvent(event)

        XCTAssertNil(appState.sessions["remote:devbox_t4:stale"])
        XCTAssertNotNil(appState.sessions["remote:devbox_t4:kept"])
        XCTAssertNil(appState.sessions["default"])
    }

    private func remoteSession(
        status: AgentStatus,
        lastActivity: Date,
        source: String = "claude"
    ) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.status = status
        session.lastActivity = lastActivity
        session.remoteHostId = "devbox_t4"
        session.remoteHostName = "devbox_t4"
        session.source = source
        return session
    }
}
