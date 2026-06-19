# Refactor Plan — Harden the `SessionState` Pure Reducer

> Status: proposal · Author: drafted with Claude Code · Date: 2026-06-19
>
> Goal: finish the reducer extraction that is already ~60% done, so that **all
> session-state transitions live in one pure, deterministic, fully-tested
> function** and `AppState` is left holding only side effects and wiring.
>
> Reference: this mirrors the architecture used by the internal `flux-desktop-app`
> (an Electron sibling of CodeIsland), whose `SessionState.apply()` is a strict
> pure reducer with all per-agent quirks pushed to adapter/normalization layers.
> We are not copying its code — only the discipline.

---

## 1. Where we are today (the good news)

CodeIsland has **already started down this path**. The substrate exists:

| Piece | Location | State |
|---|---|---|
| Normalized event-name map | `EventNormalizer.normalize(_:)` (`CodeIslandCore/EventNormalizer.swift`) | ✅ pure, table-driven, covers ~9 agents |
| Reducer | `reduceEvent(sessions:event:maxHistory:) -> [SideEffect]` (`CodeIslandCore/SessionSnapshot.swift:577`) | 🟡 exists, but impure & reads `rawJSON` |
| Side-effect descriptor | `enum SideEffect` (`SessionSnapshot.swift:565`) | ✅ value type, `Equatable` |
| Side-effect executor | `AppState.executeEffect(_:sessionId:)` (`AppState.swift:1033`) | ✅ clean switch |
| Derived view-model | `deriveSessionSummary(from:)` (`SessionSnapshot.swift:514`) | ✅ pure |
| State value type | `struct SessionSnapshot: Sendable` (`SessionSnapshot.swift:9`) | ✅ value type (CoW-friendly) |
| Reducer tests | `Tests/CodeIslandCoreTests/{DerivedSessionState,PiAgentEventFlow,CodexNativeSubagentRouting,MultiplexerEnvCapture}Tests.swift` | ✅ already drive `reduceEvent` |

This is a strong foundation. The plan below is **incremental hardening**, not a rewrite. Every phase ships independently and keeps the app working.

---

## 2. The gaps (what makes the reducer not yet "pure")

Concrete problems in the current `reduceEvent` and its caller `AppState.handleEvent` (`AppState.swift:918`):

### G1 — The reducer is not deterministic (calls `Date()`)
`reduceEvent` calls `Date()` directly (`SessionSnapshot.swift:774`, `:862`, plus `SessionSnapshot(startTime:)`, `addRecentMessage`, etc.). A pure reducer must be a deterministic function of `(state, event)`. Time is an **input**, not an ambient read. This is exactly the constraint flux enforces ("`Date.now()` would break determinism — pass timestamps in").

### G2 — The reducer reaches into `event.rawJSON` everywhere
The `Stop`/`SessionStart`/`Notification` branches dig directly into the raw payload bag: `rawJSON["stop_reason"]`, `rawJSON["_source"]`, `rawJSON["agent_type"]`, and ~25 `_term_*` / `_cmux_*` / `_zellij_*` / `_superset_*` / `_remote_*` keys (`SessionSnapshot.swift:743–838`). This is the anti-pattern flux explicitly forbids: **business meaning is derived inside the reducer from an untyped bag**. It means:
- The reducer can't be understood without knowing every agent's wire format.
- Schema drift in one agent silently changes reducer behavior.
- The `HookEvent` type (`Models.swift:144`) is a thin wrapper (`eventName`, `sessionId`, `toolName`, `toolUseId`, `agentId`, `toolInput`, `rawJSON`) — everything else leaks through `rawJSON`.

### G3 — State transitions are split between the reducer and `handleEvent`
`handleEvent` mutates `sessions` **outside** the reducer in several places, e.g. the `wasWaiting` blanket-drain block sets `sessions[sessionId]?.status = …` directly (`AppState.swift:980–982`), plus Cursor-YOLO detection (`:991`) and `maybeBackfillModel` (`:1050`). So "how does a session change state?" has **two** answers today. Single-source-of-truth is violated.

### G4 — Actionable/waiting state lives outside the state value
`permissionQueue`, `questionQueue`, `activeSessionId`, `modelReadRetryAt` are `AppState`-local fields with `CheckedContinuation`s. The reducer can read a session's `.status == .waitingApproval`, but the *pending request itself* (and its resolve-on-disconnect policy) is invisible to it. flux models pending permissions/questions **inside** session state with an explicit `disconnectPolicy` and a deferred-completion rule (if a session ends while waiting, park the end and finalize on resolve). We currently approximate this with scattered logic.

### G5 — A few fields carry more than one meaning
`interrupted` is written from `stop_reason ∈ {user, interrupted}` (Stop) **and** from `eventName == "TaskCancel"` (TaskRoundComplete) (`SessionSnapshot.swift:720`, `:746`). Two distinct producers, one bool. This is the "don't make one boolean carry two meanings" smell.

---

## 3. Target architecture

```
bridge socket
   │  raw JSON
   ▼
HookEvent(from: Data)            ← already exists (thin)
   │
   ▼
AgentEvent  ← NEW: fully-typed, normalized intermediate (no rawJSON downstream)
   │            built by per-agent normalization; carries `timestamp`
   ▼
SessionState.reduce(_ state, _ event) -> (SessionState, [SideEffect])
   │            PURE: no Date(), no rawJSON, no AppKit, no I/O
   ▼
AppState        ← applies new state to @Published, runs SideEffects,
                  owns queues/continuations/timers
   ▼
deriveSessionSummary / DerivedState → SwiftUI
```

The key new type is `AgentEvent`: the normalized, typed event the reducer consumes. All `rawJSON` digging moves **up** into the normalization layer (extend `EventNormalizer` into a full `HookEventNormalizer`, or add per-agent adapter funcs). The reducer then reads only typed fields.

---

## 4. Phased migration (each phase is shippable on its own)

### Phase 0 — Freeze behavior with characterization tests *(no production change)*
- Extend the existing `CodeIslandCoreTests` so every `reduceEvent` branch (each `case` in the switch) has at least one assertion on **both** the resulting `SessionSnapshot` **and** the returned `[SideEffect]`. Adopt flux's dual-track rule: asserting only final state misses "wrong/missing side-effect, state coincidentally equal" bugs.
- Add recorded real payloads as fixtures (see Phase 5) for at least claude / codex / cursor / cline so subsequent refactors are caught by regression.
- **Exit criteria:** branch coverage of `reduceEvent` is comprehensive; `swift test` green.

### Phase 1 — Make the reducer deterministic (fix G1)
- Add a `now: Date` parameter: `reduceEvent(sessions:event:now:maxHistory:)`. Thread `now` through `SessionSnapshot(startTime:)`, `lastActivity`, `recordTool`, `addRecentMessage`.
- `AppState.handleEvent` passes `Date()`; tests pass a fixed date.
- Mechanical, low-risk, unlocks time-dependent tests (rotation, completion auto-collapse).
- **Exit criteria:** no `Date()` / `Date.now` inside `CodeIslandCore` reducer path; tests can inject time.

### Phase 2 — Introduce the typed `AgentEvent` and stop reading `rawJSON` in the reducer (fix G2)
- Define `struct AgentEvent` in `CodeIslandCore` with **business-named, typed** fields the reducer needs:
  ```swift
  public struct AgentEvent: Sendable {
      public let kind: AgentEventKind          // .userPrompt / .preTool / .postTool(success:) / .stop / .sessionStart / …
      public let sessionId: String
      public let source: String                // already normalized
      public let agentId: String?              // subagent routing
      public let timestamp: Date
      // typed, optional, business-named payloads:
      public let prompt: String?
      public let assistantMessage: String?
      public let tool: ToolInvocation?         // name + description
      public let stopCause: StopCause?         // .completed / .userInterrupt  (replaces stop_reason string)
      public let terminalLocation: TerminalLocation?   // all _term_/_tmux_/_cmux_/_zellij_/… collapsed here
      public let remote: RemoteOrigin?
      public let question: QuestionPayload?
      // …add fields as branches need them; NEVER a rawJSON bag.
  }
  ```
- Move every `event.rawJSON[...]` read currently in `reduceEvent` into a `HookEvent -> AgentEvent` normalization step (extend `EventNormalizer`; keep per-agent quirks here). The `SessionStart` metadata explosion (`SessionSnapshot.swift:776–838`) becomes one `TerminalLocation` + `RemoteOrigin` mapping.
- Reducer signature becomes `reduce(_ sessions: inout [String: SessionSnapshot], _ event: AgentEvent) -> [SideEffect]` — **`rawJSON` no longer crosses into the reducer.**
- Do this branch-by-branch (Stop first — it has the most digging — then SessionStart, then the rest), keeping tests green between each.
- **Exit criteria:** `grep rawJSON CodeIslandCore/SessionSnapshot.swift` returns nothing inside the reducer; all extraction is in the normalizer.

### Phase 3 — Pull residual mutations into the reducer; converge to one transition site (fix G3)
- Move the `wasWaiting` drain/resume logic (`AppState.swift:971–986`) into a reducer branch (it's a pure state decision: "an activity event arrived while waiting → resume to processing/idle"). The *queue draining* part stays a `SideEffect` (`.drainQuestions(sessionId:)`, `.showNextPending`), but the **status mutation** moves into `reduce`.
- Same for Cursor-YOLO (`:988–992`) — model as an `AgentEvent` field set by the normalizer, not a `static detectCursorYoloMode()` call inside `handleEvent`.
- `maybeBackfillModel` stays a side effect (it does I/O), but expressed as `.backfillModel(sessionId:)`.
- After this, `handleEvent` should read roughly: `let event = normalize(hook); let fx = SessionState.reduce(&sessions, event); fx.forEach(execute); refreshDerivedState()`.
- **Exit criteria:** no `sessions[...]?.… = …` assignments remain in `AppState.handleEvent`; the only writer of `SessionSnapshot` is the reducer.

### Phase 4 — Model pending permission / question inside state (fix G4) *(largest, optional-but-valuable)*
- Add to `SessionSnapshot` (or a sibling `PendingInteraction` map keyed by session): `pendingPermissions: [PendingPermission]`, `pendingQuestions: [PendingQuestion]`, each with `toolUseId?` and a `disconnectPolicy: .resolveOnDisconnect | .preserveOnDisconnect`.
- The `CheckedContinuation` + socket writes stay in `AppState` (they are I/O), keyed off the IDs the reducer now owns. The reducer decides *what is pending*; `AppState` decides *how to answer the socket*.
- Implement flux's **deferred-completion** rule explicitly: if a `Stop`/`SessionEnd` arrives while `status == .waitingApproval/.waitingQuestion`, set a business-named `isSessionEnded` flag instead of force-flipping status; finalize in the `permissionResolved` / `questionAnswered` branch. This removes a class of "approval card vanished because the agent ended mid-prompt" bugs.
- **Exit criteria:** `permissionQueue`/`questionQueue` ordering decisions are reducer-driven and unit-tested without continuations.

### Phase 5 — Lock it in (fixtures + naming cleanup) (fix G5)
- **Record-real-payloads → replay-as-fixtures** loop: add a debug switch that dumps incoming raw `HookEvent` JSON to `Tests/Fixtures/<agent>/<n>-<scenario>.json` (flux's `HookPayloadRecorder`). Tests load these and drive `normalize → reduce`, asserting on real text fragments. New agents become "add an adapter + record a fixture".
- Split `interrupted` (G5) into producer-specific intent if the two origins ever need to diverge in UI; at minimum give `AgentEvent.stopCause` a typed enum so the bool is set in exactly one place.
- Write the conventions into `CLAUDE.md` (done alongside this plan) so the discipline survives.
- **Exit criteria:** fixture replay tests exist for the top agents; CLAUDE.md documents the reducer rules.

---

## 5. Risk / sequencing notes

- **Phases 0–2 are high-value, low-risk** and worth doing first; they make everything after testable.
- **Phase 4 is the biggest** — it touches the live permission/continuation path. Do it last, behind the Phase-0 regression net.
- The `inout [String: SessionSnapshot]` signature can stay (Swift CoW makes it efficient and it avoids rebuilding the whole map per event). "Pure" here means *no ambient reads and no side effects*, not necessarily value-returning. If a value-returning form is preferred later, it's a mechanical change once G1–G3 are done.
- ⚠️ **Commit the working tree first.** This checkout carries the uncommitted R1–R10 fork features; start the refactor on a fresh branch so a mistake is recoverable.

---

## 6. Definition of done

1. `reduceEvent` (renamed `SessionState.reduce`) is deterministic: inputs are `(sessions, AgentEvent)` only; no `Date()`, no `rawJSON`, no AppKit/SwiftUI, no I/O, no singletons.
2. `AppState.handleEvent` contains no direct `SessionSnapshot` mutation — only normalize → reduce → execute effects → refresh derived state.
3. Every reducer branch has a test asserting both resulting state and emitted side effects, plus at least one real recorded fixture per major agent.
4. The rules are codified in `CLAUDE.md`.
