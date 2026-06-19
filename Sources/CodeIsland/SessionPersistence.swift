import Foundation
import CodeIslandCore

struct PersistedSession: Codable {
    let sessionId: String
    let cwd: String?
    let source: String
    let model: String?
    let sessionTitle: String?
    let sessionTitleSource: SessionTitleSource?
    let providerSessionId: String?
    let lastUserPrompt: String?
    let lastAssistantMessage: String?
    let termApp: String?
    let itermSessionId: String?
    let ttyPath: String?
    let kittyWindowId: String?
    let tmuxPane: String?
    let tmuxClientTty: String?
    let tmuxEnv: String?
    let termBundleId: String?
    // Multiplexer / fork pane hints — preserved across launches so precise jump-back
    // (cmux focus-panel / zellij go-to-tab / wezterm activate-pane) keeps working
    // after an app restart instead of degrading to cwd/tty fallback.
    let cmuxSurfaceId: String?
    let cmuxWorkspaceId: String?
    let zellijPaneId: String?
    let zellijSessionName: String?
    let weztermPaneId: String?
    let cliPid: Int32?
    let cliStartTime: Date?
    let startTime: Date
    let lastActivity: Date
}

enum SessionPersistence {
    private static let dirPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.codeisland"
    private static let filePath = dirPath + "/sessions.json"
    /// Cap persisted sessions (mirrors AgentIsland's MAX_SESSIONS) so the file can't grow unbounded.
    private static let maxSessions = 1000
    private static let currentVersion = 1

    /// Versioned wrapper so the on-disk format can evolve without silently mis-decoding (R5).
    struct PersistedSnapshot: Codable {
        let version: Int
        let savedAt: Date
        let sessions: [PersistedSession]
    }

    static func save(_ sessions: [String: SessionSnapshot]) {
        let persisted: [PersistedSession] = sessions.compactMap { (id, s) in
            guard !s.isRemote else { return nil }
            return PersistedSession(
                sessionId: id,
                cwd: s.cwd,
                source: s.source,
                model: s.model,
                sessionTitle: s.sessionTitle,
                sessionTitleSource: s.sessionTitleSource,
                providerSessionId: s.providerSessionId,
                lastUserPrompt: s.lastUserPrompt,
                lastAssistantMessage: s.lastAssistantMessage,
                termApp: s.termApp,
                itermSessionId: s.itermSessionId,
                ttyPath: s.ttyPath,
                kittyWindowId: s.kittyWindowId,
                tmuxPane: s.tmuxPane,
                tmuxClientTty: s.tmuxClientTty,
                tmuxEnv: s.tmuxEnv,
                termBundleId: s.termBundleId,
                cmuxSurfaceId: s.cmuxSurfaceId,
                cmuxWorkspaceId: s.cmuxWorkspaceId,
                zellijPaneId: s.zellijPaneId,
                zellijSessionName: s.zellijSessionName,
                weztermPaneId: s.weztermPaneId,
                cliPid: s.cliPid,
                cliStartTime: s.cliStartTime,
                startTime: s.startTime,
                lastActivity: s.lastActivity
            )
        }
        // Keep the most recently active sessions when over the cap.
        let capped = persisted.sorted { $0.lastActivity > $1.lastActivity }.prefix(maxSessions)
        let snapshot = PersistedSnapshot(version: currentVersion, savedAt: Date(), sessions: Array(capped))
        do {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: URL(fileURLWithPath: filePath), options: Data.WritingOptions.atomic)
        } catch {}
    }

    static func load() -> [PersistedSession] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Preferred: versioned wrapper.
        if let snapshot = try? decoder.decode(PersistedSnapshot.self, from: data) {
            guard snapshot.version == currentVersion else { return [] }
            return snapshot.sessions
        }
        // Legacy fallback: a bare top-level [PersistedSession] array (pre-versioning).
        return (try? decoder.decode([PersistedSession].self, from: data)) ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
