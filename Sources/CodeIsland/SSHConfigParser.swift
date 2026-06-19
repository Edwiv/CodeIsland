import Foundation

/// A connectable host parsed from ~/.ssh/config (wildcard patterns excluded).
struct ParsedSSHHost: Identifiable, Equatable, Sendable {
    var id: String { alias }
    let alias: String
    var hostName: String?
    var user: String?
}

/// Parses ~/.ssh/config into concrete host aliases (R4). Swift port of AgentIsland's
/// `listSshHostInfos` (sshConfig.ts): skips comments/blank lines and any alias containing
/// `*`, `?`, or `!`; applies HostName/User to every alias in the current `Host` block.
enum SSHConfigParser {
    static func defaultConfigPath() -> String {
        NSString(string: "~/.ssh/config").expandingTildeInPath
    }

    static func listHosts(configPath: String = SSHConfigParser.defaultConfigPath()) -> [ParsedSSHHost] {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        var hosts: [ParsedSSHHost] = []
        var current: [Int] = []  // indices into `hosts` for the active Host block

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyRaw = parts.first else { continue }
            let key = keyRaw.lowercased()

            if key == "host" {
                current = []
                for alias in parts.dropFirst() {
                    if alias.contains("*") || alias.contains("?") || alias.contains("!") { continue }
                    if hosts.contains(where: { $0.alias == alias }) { continue }
                    hosts.append(ParsedSSHHost(alias: alias))
                    current.append(hosts.count - 1)
                }
                continue
            }

            if current.isEmpty { continue }
            if key == "hostname", parts.count > 1 {
                for i in current { hosts[i].hostName = parts[1] }
            } else if key == "user", parts.count > 1 {
                for i in current { hosts[i].user = parts[1] }
            }
        }
        return Array(hosts.prefix(60))
    }
}
