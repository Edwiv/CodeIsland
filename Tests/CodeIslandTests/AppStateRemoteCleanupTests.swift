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

    private func remoteSession(status: AgentStatus, lastActivity: Date) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.status = status
        session.lastActivity = lastActivity
        session.remoteHostId = "devbox_t4"
        session.remoteHostName = "devbox_t4"
        return session
    }
}
