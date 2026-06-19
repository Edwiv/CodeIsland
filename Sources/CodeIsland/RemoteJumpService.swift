import AppKit
import Foundation
import CodeIslandCore

/// Opens a remote (SSH) session in VS Code / Cursor via Remote-SSH (R10).
///
/// AgentIsland's JumpService runs `code --remote ssh-remote+<host> <cwd>` for remote
/// sessions; this is the Swift port. Local sessions keep going through
/// `TerminalActivator`. The editor is chosen by `SettingsKey.remoteEditor`
/// ("code" | "cursor"); we fall back to merely activating the editor app so a click
/// is never a silent no-op.
@MainActor
enum RemoteJumpService {
    static func jump(session: SessionSnapshot) {
        let editor = SettingsManager.shared.remoteEditor

        guard let hostId = session.remoteHostId,
              let host = RemoteManager.shared.host(id: hostId) else {
            activateEditorApp(editor)
            return
        }

        let authority = remoteAuthority(for: host)
        let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let cwd, !cwd.isEmpty, !authority.isEmpty else {
            activateEditorApp(editor)
            return
        }

        let folder = (cwd as NSString).lastPathComponent
        // Match key for window titles: the host part (strip any user@), e.g. VS Code shows
        // "… [SSH: devbox_l4]" in the title.
        let aliasHost = remoteAuthority(for: host).split(separator: "@").last.map(String.init) ?? authority

        // Do the (AppleScript) window scan off the main thread so the click never blocks.
        Task.detached(priority: .userInitiated) {
            // 1) If ANY installed editor (VS Code / Cursor / VSCodium) already has a window for
            //    this exact host+folder, raise THAT window. This picks the right editor, focuses
            //    the existing window, and can never cover an unrelated window.
            if Self.focusExistingRemoteWindow(matchHost: aliasHost, folder: folder) {
                return
            }
            // 2) Nothing open for it → open a NEW window (forced, so it never reuses/covers the
            //    active window) in the configured editor.
            await MainActor.run {
                if openViaURLScheme(editor: editor, authority: authority, cwd: cwd) {
                    return
                }
                if let bin = findEditorBinary(editor) {
                    launch(bin, ["--new-window", "--remote", "ssh-remote+\(authority)", cwd])
                    return
                }
                activateEditorApp(editor)
            }
        }
    }

    /// Bundle IDs of editors that support Remote-SSH and whose windows we can raise.
    nonisolated private static let editorBundleIds = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.vscodium.VSCodium",
    ]

    /// Raise the editor window (across all running editors) whose title contains both the
    /// project folder and the SSH host. Returns true if one was found and raised.
    nonisolated private static func focusExistingRemoteWindow(matchHost: String, folder: String) -> Bool {
        guard !folder.isEmpty, !matchHost.isEmpty else { return false }
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let bid = $0.bundleIdentifier else { return false }
            return editorBundleIds.contains(bid)
        }
        for app in running {
            guard let procName = app.localizedName, !procName.isEmpty else { continue }
            let script = """
            tell application "System Events"
                if not (exists process "\(escapeAS(procName))") then return "0"
                tell process "\(escapeAS(procName))"
                    set best to missing value
                    set bestLen to 999999
                    repeat with w in windows
                        try
                            set wName to name of w as text
                            if wName contains "\(escapeAS(folder))" and wName contains "\(escapeAS(matchHost))" then
                                set wLen to count of wName
                                if wLen < bestLen then
                                    set best to w
                                    set bestLen to wLen
                                end if
                            end if
                        end try
                    end repeat
                    if best is not missing value then
                        set frontmost to true
                        perform action "AXRaise" of best
                        return "1"
                    end if
                end tell
            end tell
            return "0"
            """
            if runAppleScriptResult(script) == "1" {
                return true
            }
        }
        return false
    }

    nonisolated private static func runAppleScriptResult(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }

    nonisolated private static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Open the remote folder in a NEW editor window via the URL handler (used only when no
    /// existing window matched). `windowId=_blank` forces a new window so it never reuses /
    /// covers the active one. Returns false if the scheme couldn't be opened.
    private static func openViaURLScheme(editor: String, authority: String, cwd: String) -> Bool {
        let scheme = (editor == "cursor") ? "cursor" : "vscode"
        // ssh-remote+<authority> then the absolute remote path (already begins with "/").
        let encodedPath = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd
        guard let url = URL(string: "\(scheme)://vscode-remote/ssh-remote+\(authority)\(encodedPath)?windowId=_blank") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// Authority for the `ssh-remote+` URI. Prefer the SSH-config alias (RemoteHost.host
    /// for config-sourced hosts); fall back to user@host so explicitly-entered hosts work.
    private static func remoteAuthority(for host: RemoteHost) -> String {
        let alias = host.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = host.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return alias }
        return alias.isEmpty ? host.sshTarget : "\(user)@\(alias)"
    }

    private static func findEditorBinary(_ editor: String) -> String? {
        let home = NSHomeDirectory()
        let candidates: [String]
        if editor == "cursor" {
            candidates = [
                "/opt/homebrew/bin/cursor",
                "/usr/local/bin/cursor",
                "\(home)/.local/bin/cursor",
                "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            ]
        } else {
            candidates = [
                "/opt/homebrew/bin/code",
                "/usr/local/bin/code",
                "\(home)/.local/bin/code",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            ]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Fire-and-forget launch off the main thread. `code`/`cursor` signal the running
    /// instance and exit quickly, but we never wait so the menu-bar UI can't stall.
    private static func launch(_ path: String, _ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    private static func activateEditorApp(_ editor: String) {
        let appName = editor == "cursor" ? "Cursor" : "Visual Studio Code"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", appName]
            try? p.run()
        }
    }
}
