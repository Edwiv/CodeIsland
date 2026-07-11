import AppKit
import Foundation
import Network
import os.log

@MainActor
final class RemoteManager: ObservableObject {
    static let shared = RemoteManager()
    nonisolated private static let log = Logger(subsystem: "com.codeisland", category: "RemoteManager")

    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var connectionStatus: [String: SSHForwarder.Status] = [:]
    @Published private(set) var installRunning: [String: Bool] = [:]
    @Published private(set) var lastMessage: [String: String] = [:]
    /// Hosts parsed from ~/.ssh/config (R4). The Remote settings page lists these so the
    /// user can flip auto-connect / auto-resume per host without hand-entering details.
    @Published private(set) var sshConfigHosts: [ParsedSSHHost] = []

    var onDisconnect: ((String) -> Void)?

    private var forwarders: [String: SSHForwarder] = [:]
    // Per-user remote socket path resolved at connect time (#193). Keyed by host id;
    // reused by installHooks so the SSH -R forward and the remote hooks agree.
    private var remoteSocketPaths: [String: String] = [:]
    private let defaults = UserDefaults.standard
    private let hostsKey = "remoteHosts"

    // Auto-reconnect (#92): when an ssh tunnel drops without the user asking for
    // it (laptop sleep / network blip / server bounce), schedule a retry with
    // exponential backoff instead of leaving the host silently disconnected.
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var desiredConnections: Set<String> = []
    private var connectionGenerations: [String: UInt64] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]
    private var healthProbeTasks: [String: Task<Void, Never>] = [:]
    private var connectivityRecoveryTask: Task<Void, Never>?
    private var periodicHealthTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.codeisland.remote-network-monitor")
    private var lastNetworkStatus: NWPath.Status?
    private var didStartConnectivityMonitoring = false
    private var isShuttingDown = false
    /// Guard so the launch-time orphan-tunnel sweep runs only once (startup may be re-invoked).
    private var didSweepOrphanedTunnels = false

    // Fast initial reconnect for transient drops (auto-resume), then gentle backoff capped at 30s.
    private static let reconnectBackoffSeconds: [Int] = [1, 2, 4, 8, 15, 30]
    private static let healthCheckIntervalSeconds = 60
    private static let healthProbeRetrySeconds = 3
    private static let wakeRecoveryDelaySeconds = 3

    /// Delay (seconds) before the nth reconnect attempt (1-based). Clamped to the
    /// last entry for attempts beyond the table.
    static func reconnectDelay(attempt: Int) -> Int {
        guard attempt >= 1 else { return reconnectBackoffSeconds[0] }
        let idx = min(attempt - 1, reconnectBackoffSeconds.count - 1)
        return reconnectBackoffSeconds[idx]
    }

    private init() {
        load()
        refreshSSHConfigHosts()
    }

    /// Look up a configured host by its id. Used by RemoteJumpService (R10) and the
    /// aggregation dashboard inspector (R8). RemoteManager is @MainActor, and all
    /// callers are already on the main actor.
    func host(id: String) -> RemoteHost? {
        hosts.first { $0.id == id }
    }

    // MARK: - SSH config sourcing (R4)

    /// Re-parse ~/.ssh/config into `sshConfigHosts` for the Remote settings UI.
    func refreshSSHConfigHosts() {
        sshConfigHosts = SSHConfigParser.listHosts()
    }

    /// Is this ssh-config alias already registered as a connectable host?
    func isConfigured(alias: String) -> Bool {
        hosts.contains { $0.id == alias }
    }

    /// Ensure a connectable RemoteHost record exists for an ssh-config alias. The alias is
    /// used verbatim as the ssh target so OpenSSH resolves HostName/User/Port/IdentityFile.
    @discardableResult
    private func ensureConfigHost(alias: String) -> Int {
        if let idx = hosts.firstIndex(where: { $0.id == alias }) { return idx }
        let host = RemoteHost(
            id: alias,
            name: alias,
            host: alias,
            autoConnect: SettingsManager.shared.autoConnectHosts.contains(alias),
            autoResume: SettingsManager.shared.autoResumeHosts.contains(alias)
        )
        hosts.append(host)
        save()
        return hosts.count - 1
    }

    /// Toggle auto-connect-at-startup for an ssh-config alias. Enabling also connects now.
    func setAutoConnect(alias: String, enabled: Bool) {
        var set = SettingsManager.shared.autoConnectHosts
        if enabled { set.insert(alias) } else { set.remove(alias) }
        SettingsManager.shared.autoConnectHosts = set

        let idx = ensureConfigHost(alias: alias)
        hosts[idx].autoConnect = enabled
        save()
        if enabled {
            connect(id: alias)
        }
    }

    /// Toggle auto-resume (auto-reconnect on unexpected tunnel drop) for an ssh-config alias.
    func setAutoResume(alias: String, enabled: Bool) {
        var set = SettingsManager.shared.autoResumeHosts
        if enabled { set.insert(alias) } else { set.remove(alias) }
        SettingsManager.shared.autoResumeHosts = set

        let idx = ensureConfigHost(alias: alias)
        hosts[idx].autoResume = enabled
        save()
    }

    func isAutoConnect(alias: String) -> Bool {
        SettingsManager.shared.autoConnectHosts.contains(alias)
    }

    func isAutoResume(alias: String) -> Bool {
        SettingsManager.shared.autoResumeHosts.contains(alias)
    }

    /// Ensure a host record exists for an ssh-config alias, then connect it now.
    func connectConfigAlias(_ alias: String) {
        ensureConfigHost(alias: alias)
        connect(id: alias)
    }

    func startup() {
        isShuttingDown = false
        startConnectivityMonitoring()
        // Clear any reverse-forward tunnels orphaned by a previous instance that crashed or
        // was force-quit (they pile up and churn CPU). Runs once, before we spawn our own.
        if !didSweepOrphanedTunnels {
            didSweepOrphanedTunnels = true
            SSHForwarder.killOrphanedTunnels()
        }
        for host in hosts where host.autoConnect {
            desiredConnections.insert(host.id)
            connect(id: host.id)
        }
    }

    func shutdown() {
        isShuttingDown = true
        stopConnectivityMonitoring()
        for id in Array(desiredConnections) {
            disconnect(id: id)
        }
    }

    func addHost(_ host: RemoteHost) {
        hosts.append(host)
        save()
    }

    func updateHost(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let wasConnected = (connectionStatus[host.id] == .connected)
        hosts[index] = host
        save()
        if wasConnected {
            reconnect(id: host.id)
        }
    }

    func removeHost(id: String) {
        disconnect(id: id)
        hosts.removeAll { $0.id == id }
        connectionStatus[id] = .disconnected
        installRunning[id] = false
        lastMessage[id] = nil
        save()
    }

    func reconnect(id: String) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        desiredConnections.insert(id)
        cancelScheduledReconnect(id: id)
        reconnectAttempts[id] = nil
        tearDownTunnel(id: id, notifyDisconnect: true)
        connectInternal(id: id)
    }

    func connect(id: String) {
        // User-initiated connect (or autoConnect at startup): clear any pending
        // reconnect countdown and reset the backoff attempt counter.
        guard hosts.contains(where: { $0.id == id }) else { return }
        desiredConnections.insert(id)
        cancelScheduledReconnect(id: id)
        reconnectAttempts[id] = nil
        switch connectionStatus[id] ?? .disconnected {
        case .connected, .connecting:
            return
        case .disconnected, .failed:
            break
        }
        connectInternal(id: id)
    }

    private func connectInternal(id: String) {
        guard !isShuttingDown, desiredConnections.contains(id) else { return }
        switch connectionStatus[id] ?? .disconnected {
        case .connected, .connecting:
            return
        case .disconnected, .failed:
            break
        }
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        guard !host.sshTarget.isEmpty else {
            connectionStatus[id] = .failed("invalid host")
            lastMessage[id] = "invalid host"
            scheduleReconnect(for: host)
            return
        }

        // A delayed UID probe from an older attempt must never resurrect a tunnel after a
        // disconnect/reconnect. The generation is checked again after every suspension point.
        let generation = advanceConnectionGeneration(id: id)

        let forwarder = forwarders[id] ?? SSHForwarder()
        forwarders[id] = forwarder
        forwarder.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.handleStatusChange(status, forHostId: host.id)
            }
        }

        connectionStatus[id] = .connecting
        lastMessage[id] = host.displayAddress

        Task {
            let remoteSocketPath = await RemoteInstaller.prepareRemoteSocketPath(host: host)
            guard !Task.isCancelled,
                  self.connectionGenerations[id] == generation,
                  self.desiredConnections.contains(id),
                  self.forwarders[id] === forwarder else { return }
            self.remoteSocketPaths[host.id] = remoteSocketPath
            forwarder.connect(host: host, localSocketPath: HookServer.socketPath, remoteSocketPath: remoteSocketPath)
        }
    }

    func disconnect(id: String) {
        desiredConnections.remove(id)
        cancelScheduledReconnect(id: id)
        reconnectAttempts[id] = nil
        tearDownTunnel(id: id, notifyDisconnect: true)
    }

    private func handleStatusChange(_ status: SSHForwarder.Status, forHostId hostId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }),
              desiredConnections.contains(hostId),
              !isShuttingDown else { return }
        connectionStatus[hostId] = status

        switch status {
        case .connected:
            // Tunnel is up again — forget previous failure counter.
            reconnectAttempts[hostId] = nil
            cancelScheduledReconnect(id: hostId)
            startHookInstallation(for: host)
            scheduleHealthProbe(for: host, reason: "Initial tunnel validation", delaySeconds: 1)
        case .failed(let message):
            tearDownTunnel(id: hostId, notifyDisconnect: false)
            connectionStatus[hostId] = .failed(message)
            lastMessage[hostId] = message
            onDisconnect?(hostId)
            scheduleReconnect(for: host)
        case .disconnected:
            // Intentional disconnects detach the callback before stopping the child. A
            // disconnected status reaching here is therefore unexpected and recoverable.
            tearDownTunnel(id: hostId, notifyDisconnect: false)
            connectionStatus[hostId] = .disconnected
            installRunning[hostId] = false
            onDisconnect?(hostId)
            scheduleReconnect(for: host)
        case .connecting:
            break
        }
    }

    private func scheduleReconnect(for host: RemoteHost) {
        // Auto-reconnect hosts the user opted into (auto-connect at startup, or auto-resume
        // on drop); otherwise a failing manually-triggered connect would retry forever.
        guard host.autoConnect || host.autoResume else { return }
        guard desiredConnections.contains(host.id), !isShuttingDown else { return }

        cancelScheduledReconnect(id: host.id)
        let nextAttempt = (reconnectAttempts[host.id] ?? 0) + 1
        reconnectAttempts[host.id] = nextAttempt
        let delay = Self.reconnectDelay(attempt: nextAttempt)
        lastMessage[host.id] = "Reconnecting in \(delay)s (attempt \(nextAttempt))"

        let hostId = host.id
        reconnectTasks[hostId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Task may have been cancelled after the sleep; double-check.
                guard !Task.isCancelled,
                      self.reconnectTasks[hostId] != nil,
                      self.desiredConnections.contains(hostId),
                      !self.isShuttingDown else { return }
                self.reconnectTasks[hostId] = nil
                self.connectInternal(id: hostId)
            }
        }
    }

    private func cancelScheduledReconnect(id: String) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
    }

    private func startHookInstallation(for host: RemoteHost) {
        installTasks[host.id]?.cancel()
        let generation = connectionGenerations[host.id] ?? 0
        installTasks[host.id] = Task { [weak self] in
            guard let self else { return }
            await self.installHooks(for: host, generation: generation)
        }
    }

    private func installHooks(for host: RemoteHost, generation: UInt64) async {
        installRunning[host.id] = true
        let remoteSocketPath = remoteSocketPaths[host.id] ?? host.remoteSocketPath
        let result = await RemoteInstaller.installAll(host: host, remoteSocketPath: remoteSocketPath)
        guard !Task.isCancelled,
              connectionGenerations[host.id] == generation,
              desiredConnections.contains(host.id) else { return }
        installRunning[host.id] = false
        lastMessage[host.id] = result.message
        if !result.ok {
            Self.log.warning("Remote hook installation failed for \(host.id, privacy: .public): \(result.message, privacy: .public)")
            return
        }
        // Hooks are in place and the tunnel is up — replay sessions already running on the
        // remote so they appear immediately, not only after their next hook event (#4).
        await RemoteInstaller.discoverSessions(host: host, remoteSocketPath: remoteSocketPath)
    }

    // MARK: - Connection health and system recovery

    private func startConnectivityMonitoring() {
        guard !didStartConnectivityMonitoring else { return }
        didStartConnectivityMonitoring = true

        let center = NSWorkspace.shared.notificationCenter
        let recoveryNotifications: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        workspaceObservers = recoveryNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleConnectivityRecovery(reason: name.rawValue)
                }
            }
        }

        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            DispatchQueue.main.async {
                guard let self else { return }
                let previous = self.lastNetworkStatus
                self.lastNetworkStatus = status
                if previous != nil, previous != .satisfied, status == .satisfied {
                    self.scheduleConnectivityRecovery(reason: "Network restored")
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)

        periodicHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthCheckIntervalSeconds))
                guard !Task.isCancelled, let self else { return }
                self.runPeriodicHealthChecks()
            }
        }
    }

    private func stopConnectivityMonitoring() {
        connectivityRecoveryTask?.cancel()
        connectivityRecoveryTask = nil
        periodicHealthTask?.cancel()
        periodicHealthTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkStatus = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        didStartConnectivityMonitoring = false
        for task in healthProbeTasks.values { task.cancel() }
        healthProbeTasks.removeAll()
        for task in installTasks.values { task.cancel() }
        installTasks.removeAll()
    }

    private func scheduleConnectivityRecovery(reason: String) {
        guard !isShuttingDown else { return }
        connectivityRecoveryTask?.cancel()

        // A wake commonly emits several workspace notifications. Coalesce them and wait for
        // Wi-Fi, VPN, DNS, and the SSH agent to become usable before touching live tunnels.
        connectivityRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.wakeRecoveryDelaySeconds))
            guard !Task.isCancelled, let self else { return }

            let recoverableHosts = self.hosts.filter {
                self.desiredConnections.contains($0.id) && ($0.autoConnect || $0.autoResume)
            }
            for host in recoverableHosts {
                self.reconnectAttempts[host.id] = nil
                switch self.connectionStatus[host.id] ?? .disconnected {
                case .connected:
                    self.scheduleHealthProbe(for: host, reason: reason, delaySeconds: 0)
                case .connecting:
                    break
                case .disconnected, .failed:
                    self.cancelScheduledReconnect(id: host.id)
                    self.connectInternal(id: host.id)
                }
            }
        }
    }

    private func runPeriodicHealthChecks() {
        guard !isShuttingDown else { return }
        for host in hosts where desiredConnections.contains(host.id) {
            guard connectionStatus[host.id] == .connected else { continue }
            scheduleHealthProbe(for: host, reason: "Periodic tunnel health check", delaySeconds: 0)
        }
    }

    private func scheduleHealthProbe(for host: RemoteHost, reason: String, delaySeconds: Int) {
        guard desiredConnections.contains(host.id), connectionStatus[host.id] == .connected else { return }
        healthProbeTasks[host.id]?.cancel()
        let generation = connectionGenerations[host.id] ?? 0
        let socketPath = remoteSocketPaths[host.id] ?? host.remoteSocketPath

        healthProbeTasks[host.id] = Task { [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            guard !Task.isCancelled, let self else { return }

            var result = await RemoteInstaller.probeForward(host: host, remoteSocketPath: socketPath)
            if !result.ok, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthProbeRetrySeconds))
                if !Task.isCancelled {
                    result = await RemoteInstaller.probeForward(host: host, remoteSocketPath: socketPath)
                }
            }

            guard !Task.isCancelled,
                  self.connectionGenerations[host.id] == generation,
                  self.desiredConnections.contains(host.id),
                  self.connectionStatus[host.id] == .connected else { return }
            self.healthProbeTasks[host.id] = nil

            if result.ok {
                Self.log.debug("SSH tunnel probe succeeded for \(host.id, privacy: .public)")
                return
            }
            self.markTunnelUnhealthy(host: host, message: "\(reason): \(result.message)")
        }
    }

    private func markTunnelUnhealthy(host: RemoteHost, message: String) {
        Self.log.warning("SSH tunnel unhealthy for \(host.id, privacy: .public): \(message, privacy: .public)")
        tearDownTunnel(id: host.id, notifyDisconnect: false)
        connectionStatus[host.id] = .failed(message)
        lastMessage[host.id] = message
        onDisconnect?(host.id)
        scheduleReconnect(for: host)
    }

    private func tearDownTunnel(id: String, notifyDisconnect: Bool) {
        _ = advanceConnectionGeneration(id: id)
        healthProbeTasks[id]?.cancel()
        healthProbeTasks[id] = nil
        installTasks[id]?.cancel()
        installTasks[id] = nil
        installRunning[id] = false

        if let forwarder = forwarders.removeValue(forKey: id) {
            // Detach first so an intentional process termination cannot be mistaken for a
            // fresh failure and schedule a duplicate reconnect.
            forwarder.onStatusChange = nil
            forwarder.disconnect()
        }
        remoteSocketPaths[id] = nil
        connectionStatus[id] = .disconnected
        if notifyDisconnect {
            onDisconnect?(id)
        }
    }

    @discardableResult
    private func advanceConnectionGeneration(id: String) -> UInt64 {
        let next = (connectionGenerations[id] ?? 0) &+ 1
        connectionGenerations[id] = next
        return next
    }

    private func load() {
        guard let data = defaults.data(forKey: hostsKey),
              let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) else {
            hosts = []
            return
        }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: hostsKey)
    }
}
