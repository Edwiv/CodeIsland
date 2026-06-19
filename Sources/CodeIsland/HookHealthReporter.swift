import Foundation
import CodeIslandCore

struct HookRuntimeHealth: Codable, Equatable {
    let bridgePath: String
    let hookScriptPath: String
    let socketPath: String
    let bridgeExists: Bool
    let bridgeExecutable: Bool
    let hookScriptExists: Bool
    let hookScriptExecutable: Bool
    let socketExists: Bool
    let issues: [String]
}

struct HookAgentHealth: Codable, Equatable {
    let name: String
    let source: String
    let enabled: Bool
    let cliExists: Bool
    let installed: Bool
    let configPath: String
    let displayConfigPath: String
    let configExists: Bool
    let issues: [String]
}

struct HookHealthSnapshot: Codable, Equatable {
    let generatedAt: String
    let runtime: HookRuntimeHealth
    let agents: [HookAgentHealth]
}

struct HookHealthReporter {
    static func snapshot(generatedAt: Date = Date(), fm: FileManager = .default) -> HookHealthSnapshot {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return HookHealthSnapshot(
            generatedAt: iso.string(from: generatedAt),
            runtime: runtimeHealth(fm: fm),
            agents: agentHealth(fm: fm)
        )
    }

    static func runtimeHealth(
        home: String = NSHomeDirectory(),
        socketPath: String = SocketPath.path,
        fm: FileManager = .default
    ) -> HookRuntimeHealth {
        let bridgePath = "\(home)/.codeisland/codeisland-bridge"
        let hookScriptPath = "\(home)/.codeisland/codeisland-hook.sh"
        let bridgeExists = fm.fileExists(atPath: bridgePath)
        let hookScriptExists = fm.fileExists(atPath: hookScriptPath)
        let bridgeExecutable = bridgeExists && isExecutable(path: bridgePath, fm: fm)
        let hookScriptExecutable = hookScriptExists && isExecutable(path: hookScriptPath, fm: fm)
        let socketExists = fm.fileExists(atPath: socketPath)

        var issues: [String] = []
        if !bridgeExists {
            issues.append("bridge-missing")
        } else if !bridgeExecutable {
            issues.append("bridge-not-executable")
        }
        if !hookScriptExists {
            issues.append("hook-script-missing")
        } else if !hookScriptExecutable {
            issues.append("hook-script-not-executable")
        }
        if !socketExists {
            issues.append("socket-not-found")
        }

        return HookRuntimeHealth(
            bridgePath: bridgePath,
            hookScriptPath: hookScriptPath,
            socketPath: socketPath,
            bridgeExists: bridgeExists,
            bridgeExecutable: bridgeExecutable,
            hookScriptExists: hookScriptExists,
            hookScriptExecutable: hookScriptExecutable,
            socketExists: socketExists,
            issues: issues
        )
    }

    private static func agentHealth(fm: FileManager) -> [HookAgentHealth] {
        var reports = ConfigInstaller.allCLIs.map { report(for: $0, fm: fm) }
        reports.append(openCodeReport(fm: fm))
        return reports.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func report(for cli: CLIConfig, fm: FileManager) -> HookAgentHealth {
        let enabled = ConfigInstaller.isEnabled(source: cli.source)
        let cliExists = ConfigInstaller.cliExists(source: cli.source)
        let installed = ConfigInstaller.isInstalled(source: cli.source)
        let configExists = fm.fileExists(atPath: cli.fullPath)
        var issues: [String] = []
        if !enabled {
            issues.append("disabled")
        }
        if enabled && !cliExists {
            issues.append("cli-not-detected")
        }
        if enabled && cliExists && !configExists {
            issues.append("config-missing")
        }
        if enabled && cliExists && !installed {
            issues.append("hook-not-installed")
        }

        return HookAgentHealth(
            name: cli.name,
            source: cli.source,
            enabled: enabled,
            cliExists: cliExists,
            installed: installed,
            configPath: cli.fullPath,
            displayConfigPath: cli.displayConfigPath,
            configExists: configExists,
            issues: issues
        )
    }

    private static func openCodeReport(fm: FileManager) -> HookAgentHealth {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.config/opencode/opencode.jsonc",
            "\(home)/.config/opencode/opencode.json",
            "\(home)/.config/opencode/config.json",
        ]
        let configPath = candidates.first { fm.fileExists(atPath: $0) } ?? candidates[0]
        let enabled = ConfigInstaller.isEnabled(source: "opencode")
        let cliExists = ConfigInstaller.cliExists(source: "opencode")
        let installed = ConfigInstaller.isInstalled(source: "opencode")
        let configExists = fm.fileExists(atPath: configPath)
        var issues: [String] = []
        if !enabled {
            issues.append("disabled")
        }
        if enabled && !cliExists {
            issues.append("cli-not-detected")
        }
        if enabled && cliExists && !configExists {
            issues.append("config-missing")
        }
        if enabled && cliExists && !installed {
            issues.append("plugin-not-installed")
        }

        return HookAgentHealth(
            name: "OpenCode",
            source: "opencode",
            enabled: enabled,
            cliExists: cliExists,
            installed: installed,
            configPath: configPath,
            displayConfigPath: "~/.config/opencode/opencode.jsonc",
            configExists: configExists,
            issues: issues
        )
    }

    private static func isExecutable(path: String, fm: FileManager) -> Bool {
        guard
            let attrs = try? fm.attributesOfItem(atPath: path),
            let permissions = attrs[.posixPermissions] as? NSNumber
        else {
            return false
        }
        return permissions.intValue & 0o111 != 0
    }
}
