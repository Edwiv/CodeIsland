import AppKit
import ServiceManagement

enum AppVersion {
    /// Update this each release. Used as fallback when Info.plist is unavailable (debug builds).
    static let fallback = "1.0.24"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallback
    }
}

enum NotchHeightMode: String, CaseIterable {
    case matchNotch = "matchNotch"
    case matchMenuBar = "matchMenuBar"
    case custom = "custom"
}

enum SettingsKey {
    // Language
    static let appLanguage = "appLanguage"                 // "system", "en", "zh", "de", "ja", "ko", "tr"

    // General - System
    static let launchAtLogin = "launchAtLogin"
    static let displayChoice = "displayChoice"             // "auto", "builtin", "main"
    static let allowHorizontalDrag = "allowHorizontalDrag"
    static let panelHorizontalOffset = "panelHorizontalOffset"

    // General - Behavior
    static let hideInFullscreen = "hideInFullscreen"
    static let hideWhenNoSession = "hideWhenNoSession"
    static let smartSuppress = "smartSuppress"
    static let collapseOnMouseLeave = "collapseOnMouseLeave"
    static let autoCollapseAfterSessionJump = "autoCollapseAfterSessionJump"
    static let autoExpandOnCompletion = "autoExpandOnCompletion"
    static let pluginSessionMode = "pluginSessionMode"  // "separate" | "merge" | "hide"
    static let hapticOnHover = "hapticOnHover"
    static let hapticIntensity = "hapticIntensity"      // 1=light, 2=medium, 3=strong
    static let sessionTimeout = "sessionTimeout"
    // Anti-mistouch hover-expand delay, in milliseconds (R3). Default 50ms.
    static let hoverExpandDelayMs = "hoverExpandDelayMs"

    // Island appearance
    static let showMascot = "showMascot"                // true = animated pixel mascot, false = minimal app icon
    static let glowRingEnabled = "glowRingEnabled"       // outer glow ring around the island
    static let glowRingWhenCollapsed = "glowRingWhenCollapsed" // show the glow while collapsed (not expanded)
    static let glowIntensityPct = "glowIntensityPct"     // glow brightness for waiting/done, percent (50–200)
    static let glowRunningIntensityPct = "glowRunningIntensityPct" // glow brightness for the running/working state, percent (0–200)
    static let reserveMenuBarWidth = "reserveMenuBarWidth" // reserve real menu-bar width so neighbor icons reflow
    static let completionDisplaySeconds = "completionDisplaySeconds" // how long the completion card stays before auto-collapse

    // Remote
    static let remoteEditor = "remoteEditor"             // "code" | "cursor" — editor for SSH remote jump
    static let autoConnectHosts = "autoConnectHosts"     // comma-separated ssh-config aliases to auto-connect
    static let autoResumeHosts = "autoResumeHosts"       // comma-separated ssh-config aliases to auto-resume

    // Display
    static let maxPanelHeight = "maxPanelHeight"
    static let maxVisibleSessions = "maxVisibleSessions"
    static let contentFontSize = "contentFontSize"
    static let aiMessageLines = "aiMessageLines"
    static let showAgentDetails = "showAgentDetails"
    static let notchHeightMode = "notchHeightMode"
    static let customNotchHeight = "customNotchHeight"

    // Expanded session row: which detail chips to show (#5)
    static let chipShowElapsed = "chipShowElapsed"
    static let chipShowModel = "chipShowModel"
    static let chipShowToolCount = "chipShowToolCount"
    static let chipShowCwd = "chipShowCwd"
    static let chipShowPermissionMode = "chipShowPermissionMode"
    static let chipShowTokens = "chipShowTokens"
    static let chipShowContextWindow = "chipShowContextWindow"

    // Sound
    static let soundEnabled = "soundEnabled"
    static let soundVolume = "soundVolume"
    static let soundSessionStart = "soundSessionStart"
    static let soundTaskComplete = "soundTaskComplete"
    static let soundTaskError = "soundTaskError"
    static let soundApprovalNeeded = "soundApprovalNeeded"
    static let soundPromptSubmit = "soundPromptSubmit"
    static let soundBoot = "soundBoot"

    // Shortcuts (per-action: shortcut_{action}_enabled, shortcut_{action}_keyCode, shortcut_{action}_modifiers)
    static func shortcutEnabled(_ action: String) -> String { "shortcut_\(action)_enabled" }
    static func shortcutKeyCode(_ action: String) -> String { "shortcut_\(action)_keyCode" }
    static func shortcutModifiers(_ action: String) -> String { "shortcut_\(action)_modifiers" }

    // Custom sound paths (keyed by sound name, e.g. "soundCustomPath_8bit_start")
    static func soundCustomPath(_ soundName: String) -> String { "soundCustomPath_\(soundName)" }

    // Session rotation
    static let rotationInterval = "rotationInterval"

    // Advanced
    static let maxToolHistory = "maxToolHistory"

    // Mascot
    static let mascotSpeed = "mascotSpeed"

    // Session grouping
    static let sessionGroupingMode = "sessionGroupingMode"

    // Tool status display
    static let showToolStatus = "showToolStatus"              // true = detailed, false = simple

    // Island collapsed width scale (percentage: 50–150, default 100)
    static let collapsedWidthScale = "collapsedWidthScale"

    // Default mascot source when no sessions exist (falls back to this instead of always "claude")
    static let defaultSource = "defaultSource"

    // Buddy companion device
    static let esp32BridgeEnabled = "esp32BridgeEnabled"
    static let esp32HeartbeatSeconds = "esp32HeartbeatSeconds"
    static let buddyScreenBrightnessPercent = "buddyScreenBrightnessPercent"
    static let buddyScreenOrientation = "buddyScreenOrientation"
    static let selectedBuddyIdentifier = "selectedBuddyIdentifier"
    static let selectedBuddyName = "selectedBuddyName"

    // Apple companion (iPhone / StandBy / Apple Watch prototype)
    static let appleCompanionEnabled = "appleCompanionEnabled"
    static let appleCompanionHeartbeatSeconds = "appleCompanionHeartbeatSeconds"

    // Auto-approve tools (comma-separated tool names)
    static let autoApproveTools = "autoApproveTools"

    // Hook cwd exclusion (comma-separated substrings; cwd containing any drops the event)
    static let excludedHookCwdSubstrings = "excludedHookCwdSubstrings"
    // Session suppression (comma/newline-separated substrings; matching event text drops the session)
    static let sessionSuppressPatterns = "sessionSuppressPatterns"

    // Webhook forwarding: POST hook events to an external URL
    static let webhookEnabled = "webhookEnabled"
    static let webhookURL = "webhookURL"
    static let webhookEventFilter = "webhookEventFilter"  // comma-separated allow-list; empty = forward all

    // Lark (Feishu) bot push: when a confirmation stays unanswered on the desktop for
    // longer than the push delay, forward it to the user's self-built Lark bot so they
    // can approve/deny/answer from their phone.
    static let larkEnabled = "larkEnabled"
    static let larkAppId = "larkAppId"
    static let larkAppSecret = "larkAppSecret"
    static let larkTargetType = "larkTargetType"        // "dm" (email/user_id) | "group" (chat_id)
    static let larkTargetValue = "larkTargetValue"
    static let larkPushDelaySeconds = "larkPushDelaySeconds"
    static let larkIncludeQuestions = "larkIncludeQuestions"
}

struct SettingsDefaults {
    static let displayChoice = "auto"
    static let allowHorizontalDrag = false
    static let panelHorizontalOffset = 0.0
    static let hideInFullscreen = true
    static let hideWhenNoSession = false
    static let smartSuppress = true
    static let collapseOnMouseLeave = true
    static let autoCollapseAfterSessionJump = false
    static let autoExpandOnCompletion = true
    static let pluginSessionMode = "separate"
    static let hapticOnHover = false
    static let hapticIntensity = 1          // 1=light
    static let sessionTimeout = 30
    static let hoverExpandDelayMs = 50

    static let showMascot = true
    static let glowRingEnabled = true
    static let glowRingWhenCollapsed = true
    static let glowIntensityPct = 130
    static let glowRunningIntensityPct = 100
    static let reserveMenuBarWidth = true
    static let completionDisplaySeconds = 7

    static let remoteEditor = "code"
    static let autoConnectHosts = ""
    static let autoResumeHosts = ""

    static let maxPanelHeight = 560
    static let maxVisibleSessions = 5
    static let contentFontSize = 11
    static let aiMessageLines = 1
    static let showAgentDetails = false
    static let notchHeightMode = NotchHeightMode.matchNotch.rawValue
    static let customNotchHeight = 37.0

    // Detail chips: only elapsed runtime is on by default (preserves current behavior).
    static let chipShowElapsed = true
    static let chipShowModel = false
    static let chipShowToolCount = false
    static let chipShowCwd = false
    static let chipShowPermissionMode = false
    static let chipShowTokens = false
    static let chipShowContextWindow = false

    static let soundEnabled = false
    static let soundVolume = 50
    static let soundSessionStart = true
    static let soundTaskComplete = true
    static let soundTaskError = true
    static let soundApprovalNeeded = true
    static let soundPromptSubmit = false
    static let soundBoot = true

    static let rotationInterval = 5

    static let maxToolHistory = 20

    static let mascotSpeed = 100  // percentage: 0–300, 0 = silent

    static let sessionGroupingMode = "all"

    static let showToolStatus = true

    static let collapsedWidthScale = 100  // percentage

    static let defaultSource = "claude"

    static let esp32BridgeEnabled = false
    static let esp32HeartbeatSeconds = 5.0
    static let buddyScreenBrightnessPercent = 70.0
    static let buddyScreenOrientation = "up"
    static let selectedBuddyIdentifier = ""
    static let selectedBuddyName = ""

    static let appleCompanionEnabled = false
    static let appleCompanionHeartbeatSeconds = 5.0

    // Default to no auto-approval — every tool call goes through the
    // approval flow and the user opts in per tool. The previous default
    // silently approved 9 internal agent tools (TaskCreate, TodoWrite,
    // EnterPlanMode etc.) which hid those calls from the panel.
    static let autoApproveTools = ""

    static let excludedHookCwdSubstrings = ""
    static let sessionSuppressPatterns = ""

    static let webhookEnabled = false
    static let webhookURL = ""
    static let webhookEventFilter = ""

    static let larkEnabled = false
    static let larkAppId = ""
    static let larkTargetType = "dm"
    static let larkTargetValue = ""
    static let larkPushDelaySeconds = 30
    static let larkIncludeQuestions = true
}

@MainActor
class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            SettingsKey.displayChoice: SettingsDefaults.displayChoice,
            SettingsKey.allowHorizontalDrag: SettingsDefaults.allowHorizontalDrag,
            SettingsKey.panelHorizontalOffset: SettingsDefaults.panelHorizontalOffset,
            SettingsKey.hideInFullscreen: SettingsDefaults.hideInFullscreen,
            SettingsKey.hideWhenNoSession: SettingsDefaults.hideWhenNoSession,
            SettingsKey.smartSuppress: SettingsDefaults.smartSuppress,
            SettingsKey.collapseOnMouseLeave: SettingsDefaults.collapseOnMouseLeave,
            SettingsKey.autoCollapseAfterSessionJump: SettingsDefaults.autoCollapseAfterSessionJump,
            SettingsKey.autoExpandOnCompletion: SettingsDefaults.autoExpandOnCompletion,
            SettingsKey.pluginSessionMode: SettingsDefaults.pluginSessionMode,
            SettingsKey.hapticOnHover: SettingsDefaults.hapticOnHover,
            SettingsKey.hapticIntensity: SettingsDefaults.hapticIntensity,
            SettingsKey.sessionTimeout: SettingsDefaults.sessionTimeout,
            SettingsKey.hoverExpandDelayMs: SettingsDefaults.hoverExpandDelayMs,
            SettingsKey.showMascot: SettingsDefaults.showMascot,
            SettingsKey.glowRingEnabled: SettingsDefaults.glowRingEnabled,
            SettingsKey.glowRingWhenCollapsed: SettingsDefaults.glowRingWhenCollapsed,
            SettingsKey.glowIntensityPct: SettingsDefaults.glowIntensityPct,
            SettingsKey.glowRunningIntensityPct: SettingsDefaults.glowRunningIntensityPct,
            SettingsKey.reserveMenuBarWidth: SettingsDefaults.reserveMenuBarWidth,
            SettingsKey.completionDisplaySeconds: SettingsDefaults.completionDisplaySeconds,
            SettingsKey.remoteEditor: SettingsDefaults.remoteEditor,
            SettingsKey.autoConnectHosts: SettingsDefaults.autoConnectHosts,
            SettingsKey.autoResumeHosts: SettingsDefaults.autoResumeHosts,
            SettingsKey.maxPanelHeight: SettingsDefaults.maxPanelHeight,
            SettingsKey.maxVisibleSessions: SettingsDefaults.maxVisibleSessions,
            SettingsKey.contentFontSize: SettingsDefaults.contentFontSize,
            SettingsKey.aiMessageLines: SettingsDefaults.aiMessageLines,
            SettingsKey.showAgentDetails: SettingsDefaults.showAgentDetails,
            SettingsKey.notchHeightMode: SettingsDefaults.notchHeightMode,
            SettingsKey.customNotchHeight: SettingsDefaults.customNotchHeight,
            SettingsKey.chipShowElapsed: SettingsDefaults.chipShowElapsed,
            SettingsKey.chipShowModel: SettingsDefaults.chipShowModel,
            SettingsKey.chipShowToolCount: SettingsDefaults.chipShowToolCount,
            SettingsKey.chipShowCwd: SettingsDefaults.chipShowCwd,
            SettingsKey.chipShowPermissionMode: SettingsDefaults.chipShowPermissionMode,
            SettingsKey.chipShowTokens: SettingsDefaults.chipShowTokens,
            SettingsKey.chipShowContextWindow: SettingsDefaults.chipShowContextWindow,
            SettingsKey.soundEnabled: SettingsDefaults.soundEnabled,
            SettingsKey.soundVolume: SettingsDefaults.soundVolume,
            SettingsKey.soundSessionStart: SettingsDefaults.soundSessionStart,
            SettingsKey.soundTaskComplete: SettingsDefaults.soundTaskComplete,
            SettingsKey.soundTaskError: SettingsDefaults.soundTaskError,
            SettingsKey.soundApprovalNeeded: SettingsDefaults.soundApprovalNeeded,
            SettingsKey.soundPromptSubmit: SettingsDefaults.soundPromptSubmit,
            SettingsKey.soundBoot: SettingsDefaults.soundBoot,
            SettingsKey.rotationInterval: SettingsDefaults.rotationInterval,
            SettingsKey.maxToolHistory: SettingsDefaults.maxToolHistory,
            SettingsKey.mascotSpeed: SettingsDefaults.mascotSpeed,
            SettingsKey.sessionGroupingMode: SettingsDefaults.sessionGroupingMode,
            SettingsKey.showToolStatus: SettingsDefaults.showToolStatus,
            SettingsKey.collapsedWidthScale: SettingsDefaults.collapsedWidthScale,
            SettingsKey.esp32BridgeEnabled: SettingsDefaults.esp32BridgeEnabled,
            SettingsKey.esp32HeartbeatSeconds: SettingsDefaults.esp32HeartbeatSeconds,
            SettingsKey.buddyScreenBrightnessPercent: SettingsDefaults.buddyScreenBrightnessPercent,
            SettingsKey.buddyScreenOrientation: SettingsDefaults.buddyScreenOrientation,
            SettingsKey.selectedBuddyIdentifier: SettingsDefaults.selectedBuddyIdentifier,
            SettingsKey.selectedBuddyName: SettingsDefaults.selectedBuddyName,
            SettingsKey.appleCompanionEnabled: SettingsDefaults.appleCompanionEnabled,
            SettingsKey.appleCompanionHeartbeatSeconds: SettingsDefaults.appleCompanionHeartbeatSeconds,
            SettingsKey.defaultSource: SettingsDefaults.defaultSource,
            SettingsKey.autoApproveTools: SettingsDefaults.autoApproveTools,
            SettingsKey.excludedHookCwdSubstrings: SettingsDefaults.excludedHookCwdSubstrings,
            SettingsKey.sessionSuppressPatterns: SettingsDefaults.sessionSuppressPatterns,
            SettingsKey.webhookEnabled: SettingsDefaults.webhookEnabled,
            SettingsKey.webhookURL: SettingsDefaults.webhookURL,
            SettingsKey.webhookEventFilter: SettingsDefaults.webhookEventFilter,
            SettingsKey.larkEnabled: SettingsDefaults.larkEnabled,
            SettingsKey.larkAppId: SettingsDefaults.larkAppId,
            SettingsKey.larkTargetType: SettingsDefaults.larkTargetType,
            SettingsKey.larkTargetValue: SettingsDefaults.larkTargetValue,
            SettingsKey.larkPushDelaySeconds: SettingsDefaults.larkPushDelaySeconds,
            SettingsKey.larkIncludeQuestions: SettingsDefaults.larkIncludeQuestions,
        ])
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // Login item update may fail silently in sandboxed environments
            }
        }
    }

    var displayChoice: String {
        get { defaults.string(forKey: SettingsKey.displayChoice) ?? SettingsDefaults.displayChoice }
        set { defaults.set(newValue, forKey: SettingsKey.displayChoice) }
    }

    var allowHorizontalDrag: Bool {
        get { defaults.bool(forKey: SettingsKey.allowHorizontalDrag) }
        set { defaults.set(newValue, forKey: SettingsKey.allowHorizontalDrag) }
    }

    var panelHorizontalOffset: Double {
        get { defaults.double(forKey: SettingsKey.panelHorizontalOffset) }
        set { defaults.set(newValue, forKey: SettingsKey.panelHorizontalOffset) }
    }

    var hideInFullscreen: Bool {
        get { defaults.bool(forKey: SettingsKey.hideInFullscreen) }
        set { defaults.set(newValue, forKey: SettingsKey.hideInFullscreen) }
    }

    var hideWhenNoSession: Bool {
        get { defaults.bool(forKey: SettingsKey.hideWhenNoSession) }
        set { defaults.set(newValue, forKey: SettingsKey.hideWhenNoSession) }
    }

    var smartSuppress: Bool {
        get { defaults.bool(forKey: SettingsKey.smartSuppress) }
        set { defaults.set(newValue, forKey: SettingsKey.smartSuppress) }
    }

    var collapseOnMouseLeave: Bool {
        get { defaults.bool(forKey: SettingsKey.collapseOnMouseLeave) }
        set { defaults.set(newValue, forKey: SettingsKey.collapseOnMouseLeave) }
    }

    var hapticOnHover: Bool {
        get { defaults.bool(forKey: SettingsKey.hapticOnHover) }
        set { defaults.set(newValue, forKey: SettingsKey.hapticOnHover) }
    }

    var hapticIntensity: Int {
        get { defaults.integer(forKey: SettingsKey.hapticIntensity) }
        set { defaults.set(newValue, forKey: SettingsKey.hapticIntensity) }
    }

    var sessionTimeout: Int {
        get { defaults.integer(forKey: SettingsKey.sessionTimeout) }
        set { defaults.set(newValue, forKey: SettingsKey.sessionTimeout) }
    }

    var maxPanelHeight: Int {
        get { defaults.integer(forKey: SettingsKey.maxPanelHeight) }
        set { defaults.set(newValue, forKey: SettingsKey.maxPanelHeight) }
    }

    var contentFontSize: Int {
        get { defaults.integer(forKey: SettingsKey.contentFontSize) }
        set { defaults.set(newValue, forKey: SettingsKey.contentFontSize) }
    }

    var showAgentDetails: Bool {
        get { defaults.bool(forKey: SettingsKey.showAgentDetails) }
        set { defaults.set(newValue, forKey: SettingsKey.showAgentDetails) }
    }

    var notchHeightMode: NotchHeightMode {
        get {
            let raw = defaults.string(forKey: SettingsKey.notchHeightMode) ?? SettingsDefaults.notchHeightMode
            return NotchHeightMode(rawValue: raw) ?? .matchNotch
        }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.notchHeightMode) }
    }

    var customNotchHeight: Double {
        get { defaults.double(forKey: SettingsKey.customNotchHeight) }
        set { defaults.set(newValue, forKey: SettingsKey.customNotchHeight) }
    }

    var maxToolHistory: Int {
        get { defaults.integer(forKey: SettingsKey.maxToolHistory) }
        set { defaults.set(newValue, forKey: SettingsKey.maxToolHistory) }
    }

    var rotationInterval: Int {
        get { defaults.integer(forKey: SettingsKey.rotationInterval) }
        set { defaults.set(newValue, forKey: SettingsKey.rotationInterval) }
    }

    var sessionGroupingMode: String {
        get { defaults.string(forKey: SettingsKey.sessionGroupingMode) ?? SettingsDefaults.sessionGroupingMode }
        set { defaults.set(newValue, forKey: SettingsKey.sessionGroupingMode) }
    }

    var defaultSource: String {
        get { defaults.string(forKey: SettingsKey.defaultSource) ?? SettingsDefaults.defaultSource }
        set { defaults.set(newValue, forKey: SettingsKey.defaultSource) }
    }

    /// All known auto-approvable tool names (for UI display).
    static let allAutoApproveTools: [(name: String, description: String)] = [
        ("TaskCreate", "Create task"),
        ("TaskUpdate", "Update task"),
        ("TaskGet", "Get task"),
        ("TaskList", "List tasks"),
        ("TaskOutput", "Get task output"),
        ("TaskStop", "Stop task"),
        ("TodoRead", "Read todos"),
        ("TodoWrite", "Write todos"),
        ("EnterPlanMode", "Enter plan mode"),
        ("ExitPlanMode", "Exit plan mode"),
    ]

    var autoApproveTools: Set<String> {
        get {
            let raw = defaults.string(forKey: SettingsKey.autoApproveTools) ?? SettingsDefaults.autoApproveTools
            return Set(raw.split(separator: ",").map(String.init))
        }
        set {
            defaults.set(newValue.sorted().joined(separator: ","), forKey: SettingsKey.autoApproveTools)
        }
    }

    // MARK: - Island appearance

    var showMascot: Bool {
        get { defaults.object(forKey: SettingsKey.showMascot) == nil ? SettingsDefaults.showMascot : defaults.bool(forKey: SettingsKey.showMascot) }
        set { defaults.set(newValue, forKey: SettingsKey.showMascot) }
    }

    var glowRingEnabled: Bool {
        get { defaults.object(forKey: SettingsKey.glowRingEnabled) == nil ? SettingsDefaults.glowRingEnabled : defaults.bool(forKey: SettingsKey.glowRingEnabled) }
        set { defaults.set(newValue, forKey: SettingsKey.glowRingEnabled) }
    }

    /// Glow ring brightness, percent. 100 = baseline; clamped to 50…200.
    var glowIntensityPct: Int {
        get { defaults.object(forKey: SettingsKey.glowIntensityPct) == nil ? SettingsDefaults.glowIntensityPct : defaults.integer(forKey: SettingsKey.glowIntensityPct) }
        set { defaults.set(min(200, max(50, newValue)), forKey: SettingsKey.glowIntensityPct) }
    }

    /// Glow brightness for the running/working (blue) state, percent. 0 hides it; clamped to 0…200.
    var glowRunningIntensityPct: Int {
        get { defaults.object(forKey: SettingsKey.glowRunningIntensityPct) == nil ? SettingsDefaults.glowRunningIntensityPct : defaults.integer(forKey: SettingsKey.glowRunningIntensityPct) }
        set { defaults.set(min(200, max(0, newValue)), forKey: SettingsKey.glowRunningIntensityPct) }
    }

    /// Whether the glow shows while the island is collapsed (not expanded). When false, the glow
    /// appears only once the panel is open.
    var glowRingWhenCollapsed: Bool {
        get { defaults.object(forKey: SettingsKey.glowRingWhenCollapsed) == nil ? SettingsDefaults.glowRingWhenCollapsed : defaults.bool(forKey: SettingsKey.glowRingWhenCollapsed) }
        set { defaults.set(newValue, forKey: SettingsKey.glowRingWhenCollapsed) }
    }

    /// How long the green "done" completion card stays before auto-collapse, in seconds (clamped 2…20).
    var completionDisplaySeconds: Int {
        get { defaults.object(forKey: SettingsKey.completionDisplaySeconds) == nil ? SettingsDefaults.completionDisplaySeconds : defaults.integer(forKey: SettingsKey.completionDisplaySeconds) }
        set { defaults.set(min(20, max(2, newValue)), forKey: SettingsKey.completionDisplaySeconds) }
    }

    var reserveMenuBarWidth: Bool {
        get { defaults.object(forKey: SettingsKey.reserveMenuBarWidth) == nil ? SettingsDefaults.reserveMenuBarWidth : defaults.bool(forKey: SettingsKey.reserveMenuBarWidth) }
        set { defaults.set(newValue, forKey: SettingsKey.reserveMenuBarWidth) }
    }

    var hoverExpandDelayMs: Int {
        get { defaults.object(forKey: SettingsKey.hoverExpandDelayMs) == nil ? SettingsDefaults.hoverExpandDelayMs : defaults.integer(forKey: SettingsKey.hoverExpandDelayMs) }
        set { defaults.set(newValue, forKey: SettingsKey.hoverExpandDelayMs) }
    }

    // MARK: - Lark (Feishu) bot push

    var larkEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.larkEnabled) }
        set { defaults.set(newValue, forKey: SettingsKey.larkEnabled) }
    }

    var larkAppId: String {
        get { defaults.string(forKey: SettingsKey.larkAppId) ?? SettingsDefaults.larkAppId }
        set { defaults.set(newValue, forKey: SettingsKey.larkAppId) }
    }

    var larkTargetType: String {
        get { defaults.string(forKey: SettingsKey.larkTargetType) ?? SettingsDefaults.larkTargetType }
        set { defaults.set(newValue, forKey: SettingsKey.larkTargetType) }
    }

    var larkTargetValue: String {
        get { defaults.string(forKey: SettingsKey.larkTargetValue) ?? SettingsDefaults.larkTargetValue }
        set { defaults.set(newValue, forKey: SettingsKey.larkTargetValue) }
    }

    /// Seconds the desktop waits, after a confirmation is enqueued and still unanswered,
    /// before pushing it to Lark. Clamped to 0–600.
    var larkPushDelaySeconds: Int {
        get { defaults.object(forKey: SettingsKey.larkPushDelaySeconds) == nil ? SettingsDefaults.larkPushDelaySeconds : defaults.integer(forKey: SettingsKey.larkPushDelaySeconds) }
        set { defaults.set(min(600, max(0, newValue)), forKey: SettingsKey.larkPushDelaySeconds) }
    }

    var larkIncludeQuestions: Bool {
        get { defaults.object(forKey: SettingsKey.larkIncludeQuestions) == nil ? SettingsDefaults.larkIncludeQuestions : defaults.bool(forKey: SettingsKey.larkIncludeQuestions) }
        set { defaults.set(newValue, forKey: SettingsKey.larkIncludeQuestions) }
    }

    /// App Secret. Stored in UserDefaults like the rest of the config: a Keychain item can
    /// be orphaned if the app is ever replaced with a different designated requirement,
    /// silently breaking auto-start on launch. This is the user's own machine and matches
    /// how all other settings are stored.
    var larkAppSecret: String {
        get { defaults.string(forKey: SettingsKey.larkAppSecret) ?? "" }
        set { defaults.set(newValue, forKey: SettingsKey.larkAppSecret) }
    }

    // MARK: - Remote

    var remoteEditor: String {
        get { defaults.string(forKey: SettingsKey.remoteEditor) ?? SettingsDefaults.remoteEditor }
        set { defaults.set(newValue, forKey: SettingsKey.remoteEditor) }
    }

    /// SSH-config aliases the user opted into auto-connecting at startup (R4).
    var autoConnectHosts: Set<String> {
        get {
            let raw = defaults.string(forKey: SettingsKey.autoConnectHosts) ?? SettingsDefaults.autoConnectHosts
            return Set(raw.split(separator: ",").map(String.init))
        }
        set { defaults.set(newValue.sorted().joined(separator: ","), forKey: SettingsKey.autoConnectHosts) }
    }

    /// SSH-config aliases the user opted into auto-resuming discovered sessions for (R4).
    var autoResumeHosts: Set<String> {
        get {
            let raw = defaults.string(forKey: SettingsKey.autoResumeHosts) ?? SettingsDefaults.autoResumeHosts
            return Set(raw.split(separator: ",").map(String.init))
        }
        set { defaults.set(newValue.sorted().joined(separator: ","), forKey: SettingsKey.autoResumeHosts) }
    }

    /// Comma-separated list of substrings; any hook event whose `cwd` contains
    /// any of them is silently dropped by `HookServer` (#125 plugin / claude-mem).
    var excludedHookCwdSubstrings: String {
        get { defaults.string(forKey: SettingsKey.excludedHookCwdSubstrings) ?? SettingsDefaults.excludedHookCwdSubstrings }
        set { defaults.set(newValue, forKey: SettingsKey.excludedHookCwdSubstrings) }
    }

    /// Comma- or newline-separated substrings. Any session whose hook payload text
    /// contains one of them is removed and future events for that session are ignored.
    var sessionSuppressPatterns: String {
        get { defaults.string(forKey: SettingsKey.sessionSuppressPatterns) ?? SettingsDefaults.sessionSuppressPatterns }
        set { defaults.set(newValue, forKey: SettingsKey.sessionSuppressPatterns) }
    }
}

// MARK: - Shortcut Actions

struct ShortcutBinding {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyCodeToString(keyCode))
        return parts.joined()
    }

    static func keyCodeToString(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 109: "F10", 111: "F12", 103: "F11",
            118: "F4", 120: "F2", 122: "F1",
        ]
        return map[code] ?? "?"
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case togglePanel
    case approve
    case approveAlways
    case deny
    case skipQuestion
    case jumpToTerminal

    var id: String { rawValue }

    var defaultBinding: ShortcutBinding? {
        switch self {
        case .togglePanel:    return ShortcutBinding(keyCode: 34, modifiers: [.command, .shift]) // ⌘⇧I
        case .approve:        return ShortcutBinding(keyCode: 0,  modifiers: [.command, .shift]) // ⌘⇧A
        case .deny:           return ShortcutBinding(keyCode: 2,  modifiers: [.command, .shift]) // ⌘⇧D
        case .approveAlways:  return nil
        case .skipQuestion:   return nil
        case .jumpToTerminal: return nil
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .togglePanel: return true
        default: return false
        }
    }

    var isEnabled: Bool {
        let key = SettingsKey.shortcutEnabled(rawValue)
        if UserDefaults.standard.object(forKey: key) == nil { return defaultEnabled }
        return UserDefaults.standard.bool(forKey: key)
    }

    var binding: ShortcutBinding {
        let kcKey = SettingsKey.shortcutKeyCode(rawValue)
        let modKey = SettingsKey.shortcutModifiers(rawValue)
        let fallback = defaultBinding ?? ShortcutBinding(keyCode: 0, modifiers: [.command, .shift])
        let keyCode = UInt16(UserDefaults.standard.object(forKey: kcKey) != nil
            ? UserDefaults.standard.integer(forKey: kcKey)
            : Int(fallback.keyCode))
        let modRaw = UserDefaults.standard.object(forKey: modKey) != nil
            ? UInt(UserDefaults.standard.integer(forKey: modKey))
            : fallback.modifiers.rawValue
        return ShortcutBinding(
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: modRaw).intersection(.deviceIndependentFlagsMask)
        )
    }

    func setBinding(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        UserDefaults.standard.set(Int(keyCode), forKey: SettingsKey.shortcutKeyCode(rawValue))
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: SettingsKey.shortcutModifiers(rawValue))
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.shortcutEnabled(rawValue))
    }

    /// Returns the other action that conflicts with this one's binding, if any.
    func conflictingAction() -> ShortcutAction? {
        guard isEnabled else { return nil }
        let myBinding = binding
        for other in Self.allCases where other != self && other.isEnabled {
            let otherBinding = other.binding
            if otherBinding.keyCode == myBinding.keyCode && otherBinding.modifiers == myBinding.modifiers {
                return other
            }
        }
        return nil
    }
}
