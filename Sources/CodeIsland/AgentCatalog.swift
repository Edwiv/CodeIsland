import SwiftUI
import CodeIslandCore

/// Single source of truth for per-agent presentation metadata: brand colors,
/// source-alias normalization, and machine grouping.
///
/// Before this existed the brand-color table lived only in `MascotsPage.mascotList`
/// (SettingsView), the alias→icon map only in `cliIconFiles` (NotchPanelView), and
/// source labels only in `SessionSnapshot.sourceLabel`. Several features (optional
/// app-icon glyph, glow ring, machine grouping, dashboard) need one shared catalog.
enum AgentCatalog {

    /// Canonical brand color for a source identifier. Aliases are normalized first.
    /// Unknown sources fall back to a neutral gray so the UI never crashes on a new CLI.
    static func brandColor(source: String) -> Color {
        switch canonicalSource(source) {
        case "claude":        return Color(red: 0.871, green: 0.533, blue: 0.427)
        case "codex":         return Color(red: 0.92,  green: 0.92,  blue: 0.93)
        case "gemini",
             "google-antigravity":
                              return Color(red: 0.278, green: 0.588, blue: 0.894)
        case "cursor",
             "cursor-cli":    return Color(red: 0.96,  green: 0.31,  blue: 0.0)
        case "trae",
             "traecn",
             "traecli":       return Color(red: 0.96,  green: 0.31,  blue: 0.0)
        case "copilot":       return Color(red: 0.35,  green: 0.75,  blue: 0.95)
        case "qoder",
             "qoder-cli":     return Color(red: 0.165, green: 0.859, blue: 0.361)
        case "droid":         return Color(red: 0.835, green: 0.416, blue: 0.149)
        case "codebuddy",
             "codybuddycn":   return Color(red: 0.424, green: 0.302, blue: 1.0)
        case "stepfun":       return Color(red: 0.424, green: 0.302, blue: 1.0)
        case "antigravity":   return Color(red: 0.424, green: 0.302, blue: 1.0)
        case "workbuddy":     return Color(red: 0.475, green: 0.380, blue: 0.870)
        case "hermes":        return Color(red: 0.424, green: 0.302, blue: 1.0)
        case "qwen":          return Color(red: 0.486, green: 0.228, blue: 0.929)
        case "kimi":          return Color(red: 0.29,  green: 0.56,  blue: 1.0)
        case "pi":            return Color(red: 0.95,  green: 0.6,   blue: 0.75)
        case "opencode":      return Color(red: 0.55,  green: 0.55,  blue: 0.57)
        case "cline":         return Color(red: 0.00,  green: 0.70,  blue: 0.49)
        case "kiro":          return Color(red: 0.49,  green: 0.55,  blue: 0.95)
        default:              return Color(white: 0.6)
        }
    }

    /// Normalize source aliases to a canonical key. Mirrors `MascotView` (case groups)
    /// and `cliIconFiles` so color/icon/mascot lookups stay consistent. This is a thin
    /// layer over `SessionSnapshot.normalizedSupportedSource`, falling back to a trimmed
    /// lowercase value when the source isn't in the supported set.
    static func canonicalSource(_ raw: String) -> String {
        if let normalized = SessionSnapshot.normalizedSupportedSource(raw) {
            return normalized
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Friendly display name for a source identifier, used where no live `SessionSnapshot`
    /// is on hand (e.g. the idle-state activity label). Mirrors `SessionSnapshot.sourceLabel`
    /// for built-in agents and falls back to a capitalized canonical key for the long tail.
    static func displayName(for source: String) -> String {
        let canonical = canonicalSource(source)
        switch canonical {
        case "claude":            return "Claude"
        case "codex":             return "Codex"
        case "gemini":            return "Gemini"
        case "google-antigravity": return "Google Antigravity"
        case "cursor", "cursor-cli": return "Cursor"
        case "trae", "traecn", "traecli": return "Trae"
        case "copilot":           return "Copilot"
        case "qoder", "qoder-cli": return "Qoder"
        case "droid":             return "Factory"
        case "codebuddy", "codybuddycn": return "CodeBuddy"
        case "stepfun":           return "StepFun"
        case "antigravity":       return "AntiGravity"
        case "workbuddy":         return "WorkBuddy"
        case "hermes":            return "Hermes"
        case "qwen":              return "Qwen"
        case "kimi":              return "Kimi"
        case "pi":                return "Pi"
        case "opencode":          return "OpenCode"
        case "cline":             return "Cline"
        case "kiro":              return "Kiro"
        default:
            return canonical.isEmpty ? "Agent" : canonical.prefix(1).uppercased() + canonical.dropFirst()
        }
    }

    // MARK: - Machine grouping

    /// Sentinel key for the local machine group.
    static let localMachineKey = "__local__"

    /// Display name for the local machine (e.g. "Mac mini"), with a stable fallback.
    static var localMachineLabel: String {
        Host.current().localizedName ?? "Mac"
    }

    /// Group key + display label for a session's machine. Local sessions share a single
    /// `localMachineKey`; remote sessions key by `remoteHostId`. Used by both the island
    /// "group by machine" mode (R7) and the aggregation dashboard (R8).
    static func machineGroup(for session: SessionSnapshot) -> (key: String, label: String) {
        if session.isRemote, let id = session.remoteHostId, !id.isEmpty {
            return (id, session.remoteDisplayName ?? id)
        }
        return (localMachineKey, localMachineLabel)
    }
}
