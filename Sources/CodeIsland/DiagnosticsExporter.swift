import AppKit
import Foundation
import CodeIslandCore

/// One-click diagnostics export for bug reports.
/// Collects app metadata, settings, session state, CLI configs, and recent logs into a zip.
struct DiagnosticsExporter {
    struct TranscriptIndexEntry: Codable, Equatable {
        let source: String
        let path: String
        let bytes: Int64
        let modifiedAt: String
    }

    static func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CodeIsland-Diagnostics-\(timestamp()).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = try buildArchive(saveTo: url)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([zipURL])
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Archive Builder

    private static func buildArchive(saveTo destination: URL) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("CodeIsland-Diag-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("CodeIsland-Diagnostics-\(timestamp())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. Metadata
        writeJSON(metadata(), to: root.appendingPathComponent("metadata.json"))

        // 2. Session snapshots (from AppState)
        let sessionsJSON = DispatchQueue.main.sync { sessionSnapshots() }
        writeJSON(sessionsJSON, to: root.appendingPathComponent("state/sessions.json"))

        // 2b. Recent hook events ring buffer (#103). Helps reproduce
        // session-routing / source-inference issues that only show up at
        // runtime — bug reports can ship with the actual event stream.
        let hookEventsJSON = DispatchQueue.main.sync { recentHookEvents() }
        writeJSON(hookEventsJSON, to: root.appendingPathComponent("state/hook-events.json"))

        // 2c. Hook installation health. This makes "no sessions showing up"
        // reports diagnosable without asking users to manually inspect each
        // agent's config file.
        writeEncodable(HookHealthReporter.snapshot(), to: root.appendingPathComponent("state/hook-health.json"))

        // 3. CLI config files and local hook script
        copyCLIConfigs(to: root)
        copyLocalHookFiles(to: root)

        // 4. Socket status
        let socketPath = SocketPath.path
        let socketExists = fm.fileExists(atPath: socketPath)
        let socketInfo = "path: \(socketPath)\nexists: \(socketExists)\n"
        writeText(socketInfo, to: root.appendingPathComponent("state/socket.txt"))

        // 4b. Transcript index only: useful for follow-up debugging, but it
        // intentionally avoids copying transcript contents into diagnostics.
        writeEncodable(transcriptIndex(), to: root.appendingPathComponent("state/transcript-index.json"))

        // 5. Unified system logs (last 2 hours)
        let logOutput = runCommand("/usr/bin/log", args: [
            "show", "--style", "compact", "--info", "--debug",
            "--last", "2h", "--predicate", "subsystem == \"com.codeisland\""
        ])
        writeText(logOutput, to: root.appendingPathComponent("logs/unified.log"))

        // 6. sw_vers
        let swVers = runCommand("/usr/bin/sw_vers", args: [])
        writeText(swVers, to: root.appendingPathComponent("logs/sw_vers.txt"))

        // 7. Recent crash reports
        copyCrashReports(to: root.appendingPathComponent("logs/crash-reports", isDirectory: true))

        // 8. Archive manifest
        DiagnosticsManifest.write(root: root)

        // Zip
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard ProcessRunner.runSilently(
            path: "/usr/bin/ditto",
            args: ["-c", "-k", "--keepParent", root.path, destination.path],
            timeout: 120
        ) else {
            throw NSError(domain: "DiagnosticsExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ditto failed or timed out"
            ])
        }
        return destination
    }

    // MARK: - Data Collectors

    private static func metadata() -> [String: Any] {
        [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": AppVersion.current,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier,
            "socketPath": SocketPath.path,
            "settings": [
                "hideInFullscreen": UserDefaults.standard.bool(forKey: SettingsKey.hideInFullscreen),
                "hideWhenNoSession": UserDefaults.standard.bool(forKey: SettingsKey.hideWhenNoSession),
                "collapseOnMouseLeave": UserDefaults.standard.bool(forKey: SettingsKey.collapseOnMouseLeave),
                "smartSuppress": UserDefaults.standard.bool(forKey: SettingsKey.smartSuppress),
                "sessionTimeout": UserDefaults.standard.integer(forKey: SettingsKey.sessionTimeout),
                "maxVisibleSessions": UserDefaults.standard.integer(forKey: SettingsKey.maxVisibleSessions),
                "mascotSpeed": UserDefaults.standard.integer(forKey: SettingsKey.mascotSpeed),
                "displayChoice": UserDefaults.standard.string(forKey: SettingsKey.displayChoice) ?? "auto",
            ],
        ]
    }

    @MainActor
    private static func recentHookEvents() -> [[String: Any]] {
        guard let appState = (NSApp.delegate as? AppDelegate)?.appState else { return [] }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return appState.recentHookEvents.map { event in
            var dict: [String: Any] = [
                "timestamp": isoFormatter.string(from: event.timestamp),
                "eventName": event.eventName,
                "viaPlugin": event.viaPlugin,
                "payloadKeys": event.payloadKeys,
            ]
            if let source = event.source { dict["source"] = source }
            if let sessionId = event.sessionId { dict["sessionId"] = String(sessionId.prefix(12)) }
            if let toolName = event.toolName { dict["toolName"] = toolName }
            if let preview = event.promptPreview { dict["promptPreview"] = preview }
            return dict
        }
    }

    @MainActor
    private static func sessionSnapshots() -> [[String: Any]] {
        guard let appState = (NSApp.delegate as? AppDelegate)?.appState else { return [] }
        return appState.sessions.map { id, s in
            var dict: [String: Any] = [
                "id": String(id.prefix(8)),
                "status": "\(s.status)",
                "source": s.source,
                "lastActivity": ISO8601DateFormatter().string(from: s.lastActivity),
            ]
            if let cwd = s.cwd { dict["cwd"] = cwd }
            if let tool = s.currentTool { dict["currentTool"] = tool }
            if let model = s.model { dict["model"] = model }
            if let term = s.terminalName { dict["terminal"] = term }
            if let pid = s.cliPid { dict["pid"] = pid }
            dict["subagentCount"] = s.subagents.count
            dict["toolHistoryCount"] = s.toolHistory.count
            return dict
        }
    }

    // MARK: - Helpers

    private static func writeJSON(_ obj: Any, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func writeEncodable<T: Encodable>(_ value: T, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func writeText(_ text: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func copyCLIConfigs(to root: URL) {
        let fm = FileManager.default
        var copied = Set<String>()
        for cli in ConfigInstaller.allCLIs {
            copyConfigIfExists(
                from: cli.fullPath,
                destName: "\(safeFilename(cli.source))-\(safeFilename((cli.fullPath as NSString).lastPathComponent))",
                root: root,
                copied: &copied
            )
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let extraConfigs: [(String, String)] = [
            ("\(ConfigInstaller.codexHome())/config.toml", "codex-config.toml"),
            ("\(home)/.config/opencode/opencode.jsonc", "opencode-opencode.jsonc"),
            ("\(home)/.config/opencode/opencode.json", "opencode-opencode.json"),
            ("\(home)/.config/opencode/config.json", "opencode-config.json"),
            ("\(home)/.codeisland/sessions.json", "codeisland-sessions.json"),
        ]
        for (path, destName) in extraConfigs {
            copyConfigIfExists(from: path, destName: destName, root: root, copied: &copied)
        }
    }

    private static func copyLocalHookFiles(to root: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let files: [(String, String)] = [
            ("\(home)/.codeisland/codeisland-hook.sh", "hooks/codeisland-hook.sh"),
            ("\(home)/.codeisland/codeisland-remote-hook.py", "hooks/codeisland-remote-hook.py"),
            ("\(home)/.codeisland/codeisland-opencode-remote.js", "hooks/codeisland-opencode-remote.js"),
        ]
        for (path, dest) in files {
            copyIfExists(from: path, to: root.appendingPathComponent(dest))
        }
    }

    private static func copyConfigIfExists(
        from path: String,
        destName: String,
        root: URL,
        copied: inout Set<String>
    ) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !copied.contains(standardized) else { return }
        copied.insert(standardized)
        copyIfExists(from: path, to: root.appendingPathComponent("configs/\(destName)"))
    }

    private static func copyIfExists(from path: String, to url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        try? fm.copyItem(atPath: path, toPath: url.path)
    }

    private static func transcriptIndex(fm: FileManager = .default) -> [TranscriptIndexEntry] {
        let home = fm.homeDirectoryForCurrentUser.path
        let roots: [(String, String)] = [
            ("claude", "\(home)/.claude/projects"),
            ("codex", "\(ConfigInstaller.codexHome())/sessions"),
        ]
        let entries = roots.flatMap { source, path in
            transcriptEntries(source: source, root: URL(fileURLWithPath: path), fm: fm)
        }
        return entries
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(50)
            .map { $0 }
    }

    private static func transcriptEntries(
        source: String,
        root: URL,
        fm: FileManager,
        maxScanned: Int = 5_000
    ) -> [TranscriptIndexEntry] {
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var scanned = 0
        var rows: [TranscriptIndexEntry] = []
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > maxScanned { break }
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate else {
                continue
            }
            rows.append(TranscriptIndexEntry(
                source: source,
                path: abbreviateHome(url.standardizedFileURL.path),
                bytes: Int64(values?.fileSize ?? 0),
                modifiedAt: iso.string(from: modifiedAt)
            ))
        }
        return rows
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let raw = value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return name.isEmpty ? "config" : name
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }

    private static func runCommand(_ executable: String, args: [String]) -> String {
        guard let data = ProcessRunner.run(path: executable, args: args, timeout: 30) else {
            return "error: command failed or timed out"
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func copyCrashReports(to dir: URL) {
        let fm = FileManager.default
        let diagDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? fm.contentsOfDirectory(at: diagDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let recent = files
            .filter { $0.lastPathComponent.lowercased().contains("codeisland") }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
            .prefix(5)
        guard !recent.isEmpty else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in recent {
            try? fm.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
