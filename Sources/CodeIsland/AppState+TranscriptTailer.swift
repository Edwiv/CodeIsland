import Foundation
import CodeIslandCore

extension AppState {
    /// Start watching a session's transcript file for appended lines. Safe to call
    /// repeatedly with the same (session, path) pair — the tailer reattaches only
    /// when the path actually changed.
    func attachTranscriptTailerIfNeeded(sessionId: String) {
        guard let path = sessions[sessionId]?.transcriptPath, !path.isEmpty else { return }
        if attachedTranscriptPaths[sessionId] == path { return }
        attachedTranscriptPaths[sessionId] = path
        transcriptTailer.attach(sessionId: sessionId, filePath: path)
        seedTranscriptTokensIfNeeded(sessionId: sessionId, path: path)
    }

    /// The live tailer attaches at EOF, so it won't surface token usage that was already
    /// written before we attached. Read the existing tail once and apply ONLY the token /
    /// context-window fields so the context chip shows immediately — important for Codex,
    /// whose usage (`token_count` events) isn't captured by the discovery message reader, and a
    /// free win for Claude (its `% ctx` no longer waits for the next assistant turn). Messages
    /// are deliberately left to the discovery reader / live tailer to avoid duplication.
    private func seedTranscriptTokensIfNeeded(sessionId: String, path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let maxBytes: UInt64 = 131_072
        handle.seek(toFileOffset: size > maxBytes ? size - maxBytes : 0)
        var bytes = handle.readDataToEndOfFile()
        guard !bytes.isEmpty else { return }
        // Newline-terminate so scanLines parses the final (possibly un-terminated) line.
        if bytes.last != 0x0A { bytes.append(0x0A) }

        let scan = JSONLTailer.scanLines(bytes)
        guard scan.delta.inputTokens != nil || scan.delta.outputTokens != nil
            || scan.delta.cacheReadTokens != nil || scan.delta.contextWindow != nil else { return }

        applyTranscriptDelta(ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            inputTokens: scan.delta.inputTokens,
            outputTokens: scan.delta.outputTokens,
            cacheReadTokens: scan.delta.cacheReadTokens,
            cacheCreationTokens: scan.delta.cacheCreationTokens,
            contextWindow: scan.delta.contextWindow
        ))
    }

    /// Stop watching a session's transcript. Called when the session is removed or
    /// when a new transcript path supersedes an older one.
    func detachTranscriptTailer(sessionId: String) {
        attachedTranscriptPaths.removeValue(forKey: sessionId)
        transcriptTailer.detach(sessionId: sessionId)
    }

    /// Apply an incremental update produced by the tailer. Runs on the main actor.
    func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        guard var session = sessions[delta.sessionId] else { return }
        var mutated = false

        if let prompt = delta.lastUserPrompt, session.lastUserPrompt != prompt {
            session.lastUserPrompt = prompt
            if session.recentMessages.last(where: { $0.isUser })?.text != prompt {
                session.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            mutated = true
        }
        if let reply = delta.lastAssistantMessage, session.lastAssistantMessage != reply {
            session.lastAssistantMessage = reply
            if session.recentMessages.last(where: { !$0.isUser })?.text != reply {
                session.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            mutated = true
        }

        // Token usage from the latest assistant turn (#5).
        if let v = delta.inputTokens, session.lastInputTokens != v { session.lastInputTokens = v; mutated = true }
        if let v = delta.outputTokens, session.lastOutputTokens != v { session.lastOutputTokens = v; mutated = true }
        if let v = delta.cacheReadTokens, session.lastCacheReadTokens != v { session.lastCacheReadTokens = v; mutated = true }
        if let v = delta.cacheCreationTokens, session.lastCacheCreationTokens != v { session.lastCacheCreationTokens = v; mutated = true }
        // Exact context window reported by the agent (Codex's model_context_window) — overrides
        // the model-name guess so the % chip is accurate.
        if let v = delta.contextWindow, session.contextWindowOverride != v { session.contextWindowOverride = v; mutated = true }

        if mutated {
            session.lastActivity = Date()
            sessions[delta.sessionId] = session
        }
    }
}
