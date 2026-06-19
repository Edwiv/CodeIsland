# CodeIsland — Project Conventions

CodeIsland is a native macOS (Swift / SwiftUI / AppKit) menu-bar + notch app that
shows the real-time status of local AI coding agents (Claude Code, Codex, Gemini,
Cursor, Copilot, Trae, Qoder, Factory, CodeBuddy, OpenCode, Kimi, Cline, Pi, …).
Agents fire hooks → a tiny native `codeisland-bridge` binary → Unix socket
(`/tmp/codeisland-<uid>.sock`) → the app updates the notch panel.

These rules **override default behavior**. They exist to keep a fast-growing,
multi-agent codebase auditable. Most are derived from patterns the codebase
already follows; a few (marked 🎯) are the direction we are actively migrating
toward (see `docs/refactor-sessionstate-reducer.md`).

---

## Commands

| Task | Command |
|---|---|
| Build (debug) | `swift build` |
| Build + run (release `.app`) | `./build.sh` then `open .build/release/CodeIsland.app` |
| Test | `swift test` |
| Run one test | `swift test --filter <TestCaseName>` |

> Needs **full Xcode** (not just Command Line Tools) — the `#Preview` macros need
> the `PreviewsMacros` plugin. Local ad-hoc running has iCloud-xattr and
> hardened-runtime caveats; see the `build-run-recipe` memory.

---

## Module layering (the most important rule)

The package has two first-party modules. **The boundary is the architecture.**

| Module | May import | MUST NOT contain |
|---|---|---|
| `CodeIslandCore` | Foundation only | AppKit, SwiftUI, `@MainActor` UI, singletons (`SoundManager.shared` …), sockets, file I/O for side effects, **`Date()` inside the reducer** |
| `CodeIsland` (app) | `CodeIslandCore`, AppKit, SwiftUI, Sparkle, Yams | business state-transition logic that belongs in the reducer |

1. **`CodeIslandCore` is the pure, testable core.** Models, normalization, the
   reducer, derivation helpers. It has no UI and no ambient side effects, which is
   exactly why it is the only module with meaningful unit tests
   (`Tests/CodeIslandCoreTests/`). Keep it that way: if you can't unit-test a piece
   of logic without a running app, it probably belongs in Core but is reaching for
   a side effect it shouldn't.
2. **Side effects live in the app layer.** Sound, sockets, window/notch
   manipulation, terminal activation, persistence, timers, continuations — all in
   `CodeIsland`, never in `CodeIslandCore`.

---

## Session state = one pure reducer

State transitions flow through a single pipeline. Do not add a second path.

```
raw JSON → HookEvent → (normalize) → reduceEvent(&sessions, event) -> [SideEffect]
                                          │                              │
                                   mutates state                 AppState.executeEffect runs them
```

- **`reduceEvent` (`CodeIslandCore/SessionSnapshot.swift`) is the only place a
  `SessionSnapshot` may be mutated in response to an agent event.** Do not write
  `sessions[id]?.status = …` (or any session field) inside `AppState.handleEvent`
  or elsewhere. If a transition is missing, add a reducer branch — don't patch it
  in the caller. 🎯 (a few residual mutations still live in `handleEvent`; we are
  moving them in — don't add more.)
- **The reducer must be deterministic and side-effect-free.** No `SoundManager`,
  no socket writes, no window calls, no persistence. Express every side effect as
  a `SideEffect` case and let `AppState.executeEffect(_:sessionId:)` perform it.
- 🎯 **Time is an input, not an ambient read.** Pass `now: Date` into the reducer;
  don't call `Date()` inside it. (Migration in progress — new reducer code should
  take time as a parameter.)
- 🎯 **The reducer must not read `event.rawJSON`.** All raw-payload digging belongs
  in the normalization layer that turns a `HookEvent` into a typed, normalized
  event. The reducer reads typed, business-named fields only. (Migration target;
  see the refactor doc.)

---

## Cross-agent normalization

Thirteen-plus agents speak different dialects. Collapse the differences at the
**edges**, never in the core logic.

- **Event names normalize in exactly one place:** `EventNormalizer.normalize(_:)`.
  When you add an agent or a new event, add a `case` there mapping its native name
  (`beforeShellExecution`, `pre_tool_use`, `TaskStart`, …) to the internal
  PascalCase name. Never branch on a raw agent-specific event name downstream.
- **Source strings normalize through `SessionSnapshot.normalizedSupportedSource`**
  and the `supportedSources` / `ideHostSources` / `ideCompletionSources` sets.
  Adding an agent means updating those sets, not scattering string compares.
- **Per-agent quirks go in normalization/adapters, not in the reducer.** The
  reducer should be readable without knowing any agent's wire format.

---

## Field discipline (business naming)

This is the convention that keeps the state machine readable as agents multiply.

1. **Name fields by business meaning, not by generic mechanism.** A flag that means
   "this session was cancelled by the user" is `interrupted` / `userInterrupted`,
   not `flag2` or a reused `isAcknowledged`.
2. **One field = one meaning.** Never make a single boolean carry two semantics.
   If two producers set "ended" for different reasons, give them independent fields
   rather than overloading one. (Today `interrupted` is set both from a Stop
   `stop_reason` and from a Cline `TaskCancel` — that's the smell to avoid
   repeating; prefer a typed cause.)
3. **Producers set explicitly; the reducer transfers in one line.** Don't re-derive
   a session's business state by sniffing adjacent raw fields inside the reducer.
   The normalization layer decides the meaning once; the reducer copies it.
4. **Split display text from state tokens.** `currentTool` is the state-machine
   token (`"Bash"`); the human-readable description (`"Bash(npm test)"`) is a
   separate field (`toolDescription`). Don't conflate them.

---

## Side effects

- Every side effect is a `SideEffect` case (`CodeIslandCore/SessionSnapshot.swift`)
  returned by the reducer and executed by `AppState.executeEffect`. To add one:
  add the `case`, return it from the relevant reducer branch, handle it in the
  executor. This keeps the reducer pure and the effect list testable
  (`SideEffect` is `Equatable` — assert on it).
- Continuations, queues (`permissionQueue`, `questionQueue`), timers, and the
  socket live in `AppState`. The reducer may decide *that* something is pending; it
  must not perform the socket reply itself.

---

## File-size sensitivity for large reads

Several inputs are large append-only files (agent JSONL transcripts, snapshots,
logs). **Do not `String(contentsOf:)` / read a whole transcript into memory** when
you need only the tail or a few lines. Use the streaming/tailing helpers
(`JSONLTailer`, `AppState+TranscriptTailer`) — they exist for exactly this. New
code that reads a `transcript_path` or `*.jsonl` should tail, not slurp.

---

## Code style

- **Comments and identifiers in English.** This is an open-source (MIT) project
  forked from upstream `wxtsky/CodeIsland`; match the existing English comments.
  (User-facing strings are localized separately — see below.)
- **Localize all user-facing strings via `L10n`** (EN + zh-CN). Don't hardcode UI
  text in views. The few inline Chinese literals in Core (e.g. completion
  placeholders) are user-facing and intentional, but new UI text goes through L10n.
- Match the surrounding file's naming, spacing, and `// MARK:` sectioning.

---

## Fork enhancements over upstream

This is a fork of upstream **`wxtsky/CodeIsland`**; our remote is **`Edwiv/CodeIsland`**
(`origin`, default branch `main`). Everything below is **committed on `main`** and is
*our* work on top of upstream — the architecture above (reducer, normalization,
two-module layering) is upstream's and unchanged. Code comments label the first wave
of these `R1`–`R10` (ported from an earlier "AgentIsland" prototype). When you touch
any of these, keep the conventions above.

### Island / panel UI
- **Mascot toggle + live activity** (`R1`). `SettingsKey.showMascot`. When the animated
  pixel mascot is off, the left wing shows a live readout of what the active agent is
  doing right now (running tool / "Thinking" / agent name) with a pulsing status dot and
  the left-to-right shimmer — not a static icon. `MascotActivityLabel` + `ActivityDot` in
  `NotchPanelView.swift`; minimal per-app glyph chips in `AppIconGlyph.swift`.
- **Idle-session collapse.** The expanded session list shows only **active** (non-idle)
  sessions by default and hides idle ones behind a click-to-expand dropdown, in **every**
  grouping mode (ALL / STA / CLI / MAC). Rendering fewer cards keeps open/close fast with a
  large session backlog. `SessionListView` → `collapsibleGroupedList` / `groups(for:)` /
  `renderGroups(_:)` / `InactiveSessionsToggle` in `NotchPanelView.swift`.
- **Glow ring** (`R6`). Status-driven glow around the island: blue while working, orange
  (breathing) while awaiting you, green flash on completion. Rendered as a **drop-shadow of
  the black silhouette** (`.shadow` on the shape) so it hugs the rounded corners and bleeds
  out smoothly. `GlowStyle.swift` (`IslandGlowBackground` / `IslandGlowPalette`). Tunable:
  `glowRingEnabled`, `glowWhenCollapsed`, `glowIntensityPct`, and a **separate**
  `glowRunningIntensityPct` for the blue working glow.
- **Configurable hover-expand delay** (`R3`). `SettingsKey.hoverExpandDelayMs` (default
  lowered 500 → 50 ms) to balance anti-mistouch vs responsiveness.
- **Reserve menu-bar width** (`R2`). `IslandReservationItem.swift` occupies real menu-bar
  width so neighboring status icons move aside instead of being half-covered.
- **Per-session detail chips.** Elapsed / model / tool-count / cwd / permission-mode /
  tokens / context-window chips on each `SessionCard`, each gated by its own `chipShow*`
  Settings toggle. Also: removed the redundant expanded top-left app logo and the duplicate
  remote `@host` tag (the green network `TerminalBadge` already shows the host).

### Multi-machine / remote SSH
- **Per-host SSH auto-connect / auto-resume** (`R4`) parsed from `~/.ssh/config`:
  `SSHConfigParser.swift`. Faster reconnect backoff `[1, 2, 4, 8, 15, 30]` s, and
  **discovery/replay of pre-existing remote sessions** on connect. `RemoteInstaller.swift`,
  `RemoteManager.swift`, `Resources/codeisland-remote-hook.py`.
- **Hardened session persistence** (`R5`): versioned snapshot, 1000-session cap, ~20 s
  safety-net rescan, overwrite-never-delete.
- **Group-by-machine "MAC" tab** (`R7`) + **global aggregation dashboard** (`R8`):
  `AgentCatalog.machineGroup`, `DashboardView.swift`, `DashboardWindowController.swift`. The
  dashboard's filter list uses the **real per-app icons** (`AgentAppIcon`), not line glyphs.
- **Remote jump** (`R10`): open a remote session in VS Code / Cursor Remote-SSH, **focusing
  the existing editor window** matching the host + folder rather than opening a new one.
  `RemoteJumpService.swift`.
- `AgentCatalog.swift`: per-agent brand colors, source normalization, and machine grouping
  shared across the island, dashboard, and grouping tabs.

### Phone push — Lark / Feishu bot
- Forwards a desktop permission/question confirmation to the user's phone after a
  **configurable delay** if still unanswered, with **strict two-way state sync** (whoever
  answers first — desktop, iPhone Buddy, or phone card — wins; the others are recalled).
  Self-built Feishu app over a **Python sidecar** (`lark-oapi` WebSocket long connection), so
  the Swift app needs no Feishu SDK. Pieces: `LarkNotifier.swift` (orchestrator, the third
  "publisher" alongside `AppleCompanionPublisher` / `ESP32StatePublisher`),
  `LarkBridgeManager.swift` (long-running child over newline-delimited JSON on stdin/stdout),
  sidecar `Resources/codeisland-lark-bridge.py`. Settings → **Lark** page (App ID/Secret in
  UserDefaults, DM/group target, push delay, include-questions). Reuses the existing
  single-consumption `permissionQueue` / `questionQueue` + `notifyDirty()` — no new state path.
  Requires `pip3 install lark-oapi` and the Feishu console's **event subscription AND callback
  channels both set to long-connection (WebSocket)**, subscribing `card.action.trigger`.

### Diagnostics / observability
- **Context-window & token-usage tracking** per session (`SessionSnapshot`, `JSONLTailer`,
  `AppState+TranscriptTailer`); surfaced via the context-window / token chips.
- **Hook-health diagnostics + a diagnostics manifest**: `HookHealthReporter.swift`,
  `DiagnosticsManifest.swift`, wired into `DiagnosticsExporter.swift`.
- **Codex app-server** plan-mode / user-input handling: `AppState+CodexAppServer.swift`.

### Build / run (this fork's daily app)
The locally-used app is built **universal** and deployed to `/Applications`, **ad-hoc signed
without hardened runtime** (the only config that runs reliably given the iCloud-stored
`.build` xattrs) — see the `build-run-recipe` memory. `./build.sh` produces the bundle;
a deploy step copies it to `/Applications`, strips xattrs, re-signs ad-hoc, and relaunches.
Because the bundle is ad-hoc signed, **Sparkle auto-update may not apply cleanly** — to
update, `git pull` and re-run the build + deploy rather than letting Sparkle replace it.

