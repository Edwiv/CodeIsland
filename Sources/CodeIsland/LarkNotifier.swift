import Foundation
import os
import CodeIslandCore

/// Bridges CodeIsland's pending-confirmation queues to a self-built Lark (Feishu) bot, so a
/// confirmation left unanswered on the desktop for `pushDelaySeconds` gets pushed to the
/// user's phone, where they can approve / deny / answer. The phone's tap flows back through
/// the same single-consumption queue as the on-screen card and iPhone Buddy, so whichever
/// channel answers first wins and the others are updated or ignored — no double-confirm.
///
/// All Feishu protocol work lives in the Python sidecar (`LarkBridgeManager`); this class only
/// decides *when* to push, builds a neutral payload, and applies decisions to `AppState`.
/// It is the third "publisher" alongside `ESP32StatePublisher` / `AppleCompanionPublisher`.
@MainActor
final class LarkNotifier: ObservableObject {
    static let shared = LarkNotifier()

    enum Status: Equatable {
        case disabled
        case starting
        case ready(String)          // connected; associated value is the bot's display name
        case missingDependency      // `pip3 install lark-oapi` needed
        case error(String)
    }

    @Published private(set) var status: Status = .disabled

    /// Result of the last send/test, surfaced in Settings *separately* from connection status
    /// (a failed send must not drop us out of `.ready` or the user can't retry).
    struct ActionResult: Equatable { let ok: Bool; let text: String }
    @Published private(set) var lastResult: ActionResult?

    private let log = Logger(subsystem: "com.codeisland", category: "lark")
    private let bridge = LarkBridgeManager()
    private weak var appState: AppState?

    // Config (mirrored from SettingsManager via configure()).
    private var enabled = false
    private var includeQuestions = true
    private var pushDelay = 30
    private var appId = ""
    private var appSecret = ""
    private var targetType = "dm"
    private var targetValue = ""
    /// Hash of the connection-affecting inputs; lets `configure` skip a costly sidecar restart
    /// when only lightweight fields (or nothing) changed.
    private var connectionSignature = ""

    // Restart backoff for the sidecar process.
    private var restartAttempts = 0
    private let restartBackoff: [Int] = [1, 2, 4, 8, 15, 30]

    // Pending bookkeeping. One tracked item per sessionId (an agent blocks on one ask at a time).
    private struct Tracked {
        enum Kind { case approval, question }
        let reqKey: String
        let sessionId: String
        let kind: Kind
        var pushed: Bool
        var pushCount: Int
        var resolvedRemotely: Bool   // phone already updated its own card; don't overwrite it
    }
    private var generation = 0
    private var tracked: [String: Tracked] = [:]        // sessionId -> tracked
    private var pushTimers: [String: DispatchWorkItem] = [:]
    private var refreshTimers: [String: DispatchWorkItem] = [:]
    /// Lark clients can retire card actions before the underlying agent request times out.
    /// Refreshing the same reqKey keeps the existing card actionable without spamming chat.
    private let cardRefreshInterval = 240

    // MARK: - Setup

    func attach(_ appState: AppState) { self.appState = appState }

    func configure(
        enabled: Bool,
        appId: String,
        appSecret: String,
        targetType: String,
        targetValue: String,
        pushDelaySeconds: Int,
        includeQuestions: Bool
    ) {
        let newEnabled = enabled && !appId.isEmpty && !appSecret.isEmpty && !targetValue.isEmpty
        // Only the credentials/target affect the connection. Restarting the sidecar means a
        // fresh Python spawn + lark-oapi import + re-auth + WS reconnect (several seconds), so
        // do it ONLY when one of these actually changed — not on every settings tweak or test.
        let newSignature = "\(newEnabled)|\(appId)|\(appSecret)|\(targetType)|\(targetValue)"
        let connectionChanged = newSignature != connectionSignature

        self.appId = appId
        self.appSecret = appSecret
        self.targetType = targetType
        self.targetValue = targetValue
        self.pushDelay = max(0, pushDelaySeconds)
        self.includeQuestions = includeQuestions
        self.enabled = newEnabled

        guard connectionChanged else {
            // Lightweight fields (delay / include-questions) updated in place; no restart.
            notifyDirty()
            return
        }
        connectionSignature = newSignature
        larkDebugLog("configure: connection changed enabled=\(newEnabled) (toggle=\(enabled) appId=\(!appId.isEmpty) secret=\(!appSecret.isEmpty) target=\(!targetValue.isEmpty))")

        // Connection inputs changed — reset in-flight state and (re)start the sidecar.
        cancelAllTimers()
        tracked.removeAll()
        restartAttempts = 0
        lastResult = nil

        guard newEnabled else {
            bridge.stop()
            status = .disabled
            return
        }
        startBridge()
        // Catch confirmations that were already pending when the feature got enabled.
        notifyDirty()
    }

    func sendTestCard() {
        guard enabled else { return }
        bridge.send(["type": "test"])
    }

    // MARK: - Sidecar lifecycle

    private func startBridge() {
        guard let script = Bundle.appModule.url(
            forResource: "codeisland-lark-bridge",
            withExtension: "py",
            subdirectory: "Resources"
        )?.path else {
            status = .error("sidecar script missing from bundle")
            return
        }
        status = .starting
        bridge.onMessage = { [weak self] msg in self?.handleBridgeMessage(msg) }
        bridge.onExit = { [weak self] code in self?.handleBridgeExit(code) }
        bridge.start(scriptPath: script)
        bridge.send([
            "type": "config",
            "appId": appId,
            "appSecret": appSecret,
            "target": ["type": targetType, "value": targetValue],
            "i18n": Self.cardStrings(),
        ])
    }

    /// Localized card/button text passed to the (language-agnostic) sidecar so all user-facing
    /// strings stay in `L10n`. Keys match the sidecar's `t(...)` lookups.
    private static func cardStrings() -> [String: String] {
        let l = L10n.shared
        return [
            "approval_title": l["lark_card_approval_title"],
            "question_title": l["lark_card_question_title"],
            "test_title": l["lark_card_test_title"],
            "allow_once": l["lark_btn_allow_once"],
            "allow_always": l["lark_btn_allow_always"],
            "deny": l["lark_btn_deny"],
            "submit": l["lark_btn_submit"],
            "skip": l["lark_btn_skip"],
            "footer": l["lark_card_footer"],
            "resolved_desktop": l["lark_card_resolved_desktop"],
            "resolved_phone": l["lark_card_resolved_phone"],
            "test_body": l["lark_card_test_body"],
            "urgent_failed": l["lark_urgent_failed"],
            "agent": l["lark_card_agent"],
            "project": l["lark_card_project"],
            "permission": l["lark_card_permission"],
            "please_select": l["lark_card_please_select"],
            "answer_on_desktop": l["lark_card_answer_on_desktop"],
        ]
    }

    private func handleBridgeExit(_ code: Int32) {
        guard enabled else { return }
        // A missing dependency won't fix itself on restart — surface it and stop.
        if case .missingDependency = status { return }
        let delay = restartBackoff[min(restartAttempts, restartBackoff.count - 1)]
        restartAttempts += 1
        if restartAttempts == 1 { status = .starting }
        log.error("sidecar exited (code \(code)); restart in \(delay)s (attempt \(self.restartAttempts))")
        larkDebugLog("notifier: bridge exit code=\(code) → restart in \(delay)s (attempt \(self.restartAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self, self.enabled else { return }
            self.startBridge()
        }
    }

    private func handleBridgeMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            restartAttempts = 0
            status = .ready((msg["botName"] as? String) ?? "Lark Bot")
        case "error":
            let code = msg["code"] as? String ?? ""
            let detail = msg["message"] as? String ?? code
            status = (code == "missing_dep") ? .missingDependency : .error(detail)
        case "test_result":
            let ok = (msg["ok"] as? Bool) ?? false
            let text = ok ? L10n.shared["lark_test_sent"] : (msg["message"] as? String ?? "send failed")
            lastResult = ActionResult(ok: ok, text: text)
        case "send_error":
            lastResult = ActionResult(ok: false, text: msg["message"] as? String ?? "send failed")
        case "urgent_error":
            lastResult = ActionResult(ok: false, text: msg["message"] as? String ?? L10n.shared["lark_urgent_failed"])
        case "pushed":
            if let reqKey = msg["reqId"] as? String, let sid = sessionId(forReqKey: reqKey) {
                tracked[sid]?.pushed = true
            }
        case "decision":
            handleDecision(msg)
        default:
            break
        }
    }

    // MARK: - Decision (phone -> desktop)

    private func handleDecision(_ msg: [String: Any]) {
        guard let reqKey = msg["reqId"] as? String,
              let actionId = msg["actionId"] as? String,
              let sid = sessionId(forReqKey: reqKey),
              var item = tracked[sid], item.reqKey == reqKey else { return }

        // The sidecar already updated the phone card to "confirmed on phone"; suppress our
        // outbound resolve so we don't overwrite that with "handled on desktop".
        item.resolvedRemotely = true
        tracked[sid] = item

        switch item.kind {
        case .approval:
            appState?.handleLarkApproval(sessionId: sid, actionId: actionId)
        case .question:
            if actionId == "device_chat_cancel" {
                appState?.handleLarkSkip(sessionId: sid)
            } else {
                let answers = orderedAnswers(from: msg["formValue"] as? [String: Any], sessionId: sid)
                if answers.contains(where: { !$0.isEmpty }) {
                    appState?.handleLarkQuestionAnswer(sessionId: sid, answers: answers)
                } else {
                    appState?.handleLarkSkip(sessionId: sid)
                }
            }
        }
        // The queue mutated; the diff in notifyDirty() will clean up tracked + timers.
    }

    /// Map the sidecar's `form_value` ({"s_0":"1","m_1":"0,2"}) to a per-item answer string,
    /// resolving option indices back to their labels.
    private func orderedAnswers(from formValue: [String: Any]?, sessionId: String) -> [String] {
        guard let formValue, let items = questionItems(sessionId: sessionId) else { return [] }
        var answers = [String](repeating: "", count: items.count)
        for (key, raw) in formValue {
            guard let underscore = key.firstIndex(of: "_"),
                  let idx = Int(key[key.index(after: underscore)...]),
                  items.indices.contains(idx) else { continue }
            let options = items[idx].payload.options ?? []
            let labels = "\(raw)".split(separator: ",").compactMap { token -> String? in
                guard let i = Int(token.trimmingCharacters(in: .whitespaces)), options.indices.contains(i) else { return nil }
                return options[i]
            }
            answers[idx] = labels.joined(separator: ", ")
        }
        return answers
    }

    // MARK: - Queue diff (desktop state -> push / recall)

    /// Called whenever the confirmation queues may have changed. Arms a delayed push for newly
    /// pending confirmations and recalls cards for ones that got resolved on the desktop/iPhone.
    func notifyDirty() {
        guard enabled else { return }

        var current: [String: Tracked.Kind] = [:]
        for req in appState?.permissionQueue ?? [] {
            current[req.event.sessionId ?? "default"] = .approval
        }
        if includeQuestions {
            for req in appState?.questionQueue ?? [] {
                let sid = req.event.sessionId ?? "default"
                if current[sid] == nil { current[sid] = .question }   // approval takes precedence
            }
        }

        // Resolved / kind-changed -> recall card + clean up.
        for (sid, item) in tracked where current[sid] != item.kind {
            pushTimers[sid]?.cancel(); pushTimers[sid] = nil
            refreshTimers[sid]?.cancel(); refreshTimers[sid] = nil
            if item.pushed && !item.resolvedRemotely {
                bridge.send(["type": "resolve", "reqId": item.reqKey, "by": "desktop"])
            }
            tracked[sid] = nil
        }

        // Newly pending -> assign a reqKey and arm the delayed push.
        for (sid, kind) in current where tracked[sid] == nil {
            let reqKey = "\(sid)#\(generation)"
            generation += 1
            tracked[sid] = Tracked(
                reqKey: reqKey,
                sessionId: sid,
                kind: kind,
                pushed: false,
                pushCount: 0,
                resolvedRemotely: false
            )
            larkDebugLog("notifier: new pending \(kind) sid=\(sid.prefix(8)) → push in \(effectiveDelay(for: sid))s")
            armPushTimer(sessionId: sid)
        }
    }

    private func armPushTimer(sessionId: String) {
        pushTimers[sessionId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.firePush(sessionId: sessionId) }
        }
        pushTimers[sessionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(effectiveDelay(for: sessionId)), execute: work)
    }

    /// Remote SSH sessions have a 300s hook timeout, so cap their delay well under it.
    private func effectiveDelay(for sessionId: String) -> Int {
        let isRemote = appState?.sessions[sessionId]?.isRemote ?? false
        return isRemote ? min(pushDelay, 240) : pushDelay
    }

    private func firePush(sessionId: String, refresh: Bool = false) {
        pushTimers[sessionId] = nil
        if refresh { refreshTimers[sessionId] = nil }
        guard enabled, var item = tracked[sessionId] else { return }
        if item.pushed && !refresh { return }
        // Wait for the bridge to be connected; retry shortly otherwise.
        guard case .ready = status else {
            larkDebugLog("notifier: firePush deferred (status not ready) sid=\(sessionId.prefix(8))")
            armRetry(sessionId: sessionId, refresh: refresh)
            return
        }
        guard var payload = buildPushPayload(item) else {
            larkDebugLog("notifier: firePush no payload (secret/not found) sid=\(sessionId.prefix(8))")
            return
        }
        payload["refreshSeq"] = item.pushCount + 1
        if refresh {
            payload["type"] = "refresh"
        }
        item.pushed = true
        item.pushCount += 1
        tracked[sessionId] = item
        let verb = refresh ? "REFRESH" : "PUSH"
        larkDebugLog("notifier: \(verb) \(item.kind) sid=\(sessionId.prefix(8)) reqKey=\(item.reqKey) count=\(item.pushCount)")
        bridge.send(payload)
        armRefreshTimer(sessionId: sessionId)
    }

    private func armRetry(sessionId: String, refresh: Bool) {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.firePush(sessionId: sessionId, refresh: refresh) }
        }
        if refresh {
            refreshTimers[sessionId] = work
        } else {
            pushTimers[sessionId] = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func armRefreshTimer(sessionId: String) {
        refreshTimers[sessionId]?.cancel()
        guard let item = tracked[sessionId], item.pushed else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.firePush(sessionId: sessionId, refresh: true) }
        }
        refreshTimers[sessionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(cardRefreshInterval), execute: work)
    }

    // MARK: - Payload building

    private func buildPushPayload(_ item: Tracked) -> [String: Any]? {
        guard let appState else { return nil }
        let session = appState.sessions[item.sessionId]
        let agent = session?.sourceLabel ?? "Agent"
        let project = (session?.cwd as NSString?)?.lastPathComponent ?? ""
        let sessionShort = String(item.sessionId.prefix(8))

        var payload: [String: Any] = [
            "type": "push",
            "reqId": item.reqKey,
            "agent": agent,
            "project": project,
            "sessionShort": sessionShort,
        ]

        switch item.kind {
        case .approval:
            guard let req = appState.permissionQueue.first(where: { ($0.event.sessionId ?? "default") == item.sessionId }) else { return nil }
            var detail: [String: Any] = [
                "tool": req.event.toolName ?? "?",
                "allowAlways": true,
            ]
            if let desc = req.event.toolDescription, !desc.isEmpty { detail["summary"] = desc }
            if let cmd = req.event.toolInput?["command"] as? String, !cmd.isEmpty { detail["command"] = cmd }
            else if let fp = req.event.toolInput?["file_path"] as? String, !fp.isEmpty { detail["command"] = fp }
            payload["askType"] = "approval"
            payload["payload"] = detail

        case .question:
            guard let items = questionItems(sessionId: item.sessionId) else { return nil }
            // Never stream secret prompts (e.g. Codex plan-mode secrets) off-device.
            if items.contains(where: { $0.payload.isSecret }) { return nil }
            let encoded = items.map { qi -> [String: Any] in
                [
                    "question": qi.payload.question,
                    "multi": qi.multiSelect,
                    "options": qi.payload.options ?? [],
                ]
            }
            payload["askType"] = "question"
            payload["payload"] = ["items": encoded]
        }
        return payload
    }

    /// The AskUserQuestion items for a session's head question (or the single legacy question).
    private func questionItems(sessionId: String) -> [AskUserQuestionItem]? {
        guard let req = appState?.questionQueue.first(where: { ($0.event.sessionId ?? "default") == sessionId }) else { return nil }
        if let state = req.askUserQuestionState, !state.items.isEmpty { return state.items }
        return [AskUserQuestionItem(payload: req.question, answerKey: req.question.header ?? "answer", multiSelect: false)]
    }

    // MARK: - Helpers

    private func sessionId(forReqKey reqKey: String) -> String? {
        guard let hash = reqKey.lastIndex(of: "#") else { return reqKey }
        return String(reqKey[..<hash])
    }

    private func cancelAllTimers() {
        for (_, work) in pushTimers { work.cancel() }
        pushTimers.removeAll()
        for (_, work) in refreshTimers { work.cancel() }
        refreshTimers.removeAll()
    }
}
