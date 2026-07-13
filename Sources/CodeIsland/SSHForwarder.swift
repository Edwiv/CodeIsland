import Foundation

@MainActor
final class SSHForwarder {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var status: Status = .disconnected {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }

    var onStatusChange: ((Status) -> Void)?

    private var process: Process?
    private var stderrPipe: Pipe?
    private var cleanupTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastErrorMessage: String?

    func connect(host: RemoteHost, localSocketPath: String, remoteSocketPath: String) {
        disconnect()

        let target = host.sshTarget
        guard !target.isEmpty else {
            status = .failed("invalid host")
            return
        }

        generation &+= 1
        let currentGeneration = generation
        lastErrorMessage = nil
        status = .connecting

        // Remove any stale remote socket left over from a previous tunnel before
        // opening this one. macOS system SSH (LibreSSL) does not honour
        // StreamLocalBindUnlink=yes for -R forwarding, so a leftover socket causes
        // "remote port forwarding failed" on reconnect (#206). The cleanup spawns
        // its own short-lived SSH; run it off the main thread because a blocking
        // ConnectTimeout would otherwise freeze the menu-bar UI for seconds when the
        // host is unreachable. The tunnel starts only after cleanup returns, so the
        // -R bind never races the leftover socket.
        let cleanupArguments = Self.cleanupArguments(host: host, remoteSocketPath: remoteSocketPath)
        let cleanupEnvironment = Self.environment(host: host)
        cleanupTask = Task { [weak self] in
            await SSHCommandGate.shared.acquire()
            if Task.isCancelled {
                await SSHCommandGate.shared.release()
                return
            }
            _ = await ProcessRunner.runAsync(
                path: "/usr/bin/ssh",
                args: cleanupArguments,
                env: cleanupEnvironment,
                timeout: 12
            )
            await SSHCommandGate.shared.release()

            guard !Task.isCancelled, let self else { return }
            // A newer connect()/disconnect() may have superseded this attempt while the
            // cleanup SSH was queued or in flight — bail if so.
            guard self.generation == currentGeneration else { return }
            guard case .connecting = self.status else { return }
            self.cleanupTask = nil
            self.startTunnel(
                host: host,
                localSocketPath: localSocketPath,
                remoteSocketPath: remoteSocketPath,
                generation: currentGeneration
            )
        }
    }

    /// Launch the long-lived `ssh -N -R` tunnel process. Always invoked on the main
    /// actor, after `runCleanup` has cleared any leftover remote socket.
    private func startTunnel(host: RemoteHost, localSocketPath: String, remoteSocketPath: String, generation currentGeneration: UInt64) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.tunnelArguments(host: host, localSocketPath: localSocketPath, remoteSocketPath: remoteSocketPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.environment = Self.environment(host: host)

        let stderr = Pipe()
        process.standardError = stderr
        stderrPipe = stderr

        process.terminationHandler = { [weak self] proc in
            Self.closePipe(stderr)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation == currentGeneration else { return }
                if self.stderrPipe === stderr { self.stderrPipe = nil }
                self.process = nil
                if case .disconnected = self.status { return }
                let code = proc.terminationStatus
                self.status = .failed(self.lastErrorMessage ?? "ssh exited (\(code))")
            }
        }

        do {
            try process.run()
            // The child owns a duplicated write descriptor after launch. Closing the parent
            // copy ensures the read handler observes EOF when ssh exits.
            try? stderr.fileHandleForWriting.close()
            self.process = process
            startStderrMonitor(stderr, generation: currentGeneration)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak process] in
                guard let self else { return }
                guard self.generation == currentGeneration else { return }
                guard let process else { return }
                if process.isRunning {
                    self.status = .connected
                } else if case .connecting = self.status {
                    self.status = .failed("ssh exited (\(process.terminationStatus))")
                }
            }
        } catch {
            self.process = nil
            Self.closePipe(stderr)
            self.stderrPipe = nil
            status = .failed("ssh launch failed")
        }
    }

    func disconnect() {
        cleanupTask?.cancel()
        cleanupTask = nil
        if let stderrPipe { Self.closePipe(stderrPipe) }
        stderrPipe = nil

        if let process {
            status = .disconnected
            if process.isRunning {
                ProcessRunner.terminate(process)
            }
        } else {
            status = .disconnected
        }
        self.process = nil
    }

    /// Remove a stale Unix-domain socket on the remote host before forwarding by
    /// running `rm -f <remoteSocketPath>` over its own short-lived SSH.
    ///
    /// macOS system SSH (`/usr/bin/ssh`, LibreSSL build) ignores
    /// `StreamLocalBindUnlink=yes` for `-R` (remote) forwarding.  When a tunnel
    /// drops the listen socket is left behind and reconnect fails with
    /// "remote port forwarding failed for listen path …".  A quick `rm -f`
    /// over SSH sidesteps the issue.  See issue #206.
    ///
    /// One-time startup sweep: kill reverse-forward SSH tunnels orphaned (reparented to
    /// launchd) by a previous CodeIsland instance that exited without running `disconnect()`
    /// — e.g. a crash or force-quit. Without this they accumulate across restarts and hold
    /// stale remote listen sockets, and the process churn drives high system CPU. MUST be
    /// called at launch BEFORE this instance spawns any tunnels: at that point every match
    /// is necessarily an orphan. Matches only our `-R /tmp/codeisland…sock` reverse forwards,
    /// never the user's interactive ssh or a ControlMaster session.
    nonisolated static func killOrphanedTunnels() {
        ProcessRunner.runSilently(
            path: "/usr/bin/pkill",
            args: ["-f", "ssh .*-R /tmp/codeisland.*\\.sock"],
            timeout: 5
        )
    }

    /// Build SSH arguments that remove a stale remote socket file.
    /// Extracted for testability.  See `cleanupStaleRemoteSocket`.
    static func cleanupArguments(host: RemoteHost, remoteSocketPath: String) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
        ]
        if let port = host.port {
            args += ["-p", String(port)]
        }
        let trimmedIdentity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args += ["-i", trimmedIdentity]
        }
        args += [host.sshTarget, "rm", "-f", remoteSocketPath]
        return args
    }

    static func tunnelArguments(host: RemoteHost, localSocketPath: String, remoteSocketPath: String) -> [String] {
        var args: [String] = [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectionAttempts=1",
            "-o", "TCPKeepAlive=yes",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "StreamLocalBindMask=0000",
            // Never reuse or spawn a multiplexing master connection (#190): a shared
            // ControlMaster makes `ssh -N` hand the forward to the master and exit 0
            // immediately, which we'd misread as a failed tunnel. Force a dedicated
            // connection that stays alive for the lifetime of this forwarder.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ]

        if let port = host.port {
            args += ["-p", String(port)]
        }

        let trimmedIdentity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args += ["-i", trimmedIdentity]
        }

        args += ["-R", "\(remoteSocketPath):\(localSocketPath)"]
        args.append(host.sshTarget)
        return args
    }

    /// Merge the host-specific SSH_AUTH_SOCK (if any) into the spawn environment so
    /// agents fronted by a password manager (1Password, Bitwarden, etc.) can sign
    /// the handshake even when the GUI app didn't inherit the env var from a shell.
    /// See issue #81.
    nonisolated static func environment(
        host: RemoteHost,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let trimmed = host.authSocket.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            env["SSH_AUTH_SOCK"] = expanded
        }
        return env
    }

    private func startStderrMonitor(_ pipe: Pipe, generation: UInt64) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                try? fileHandle.close()
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation == generation else { return }
                if !message.lowercased().hasPrefix("warning:") {
                    self.lastErrorMessage = message
                }
                if case .connecting = self.status {
                    self.status = .failed(message)
                }
            }
        }
    }

    nonisolated private static func closePipe(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}
