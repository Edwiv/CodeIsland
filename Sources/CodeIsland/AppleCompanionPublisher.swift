import Combine
import Foundation
import MultipeerConnectivity
import Network
import os
import CodeIslandCore

@MainActor
final class AppleCompanionPublisher: NSObject, ObservableObject {
    static let shared = AppleCompanionPublisher()

    private static let serviceType = "codeisland"
    private static let log = Logger(subsystem: "com.codeisland", category: "apple-companion")

    @Published private(set) var enabled = false
    @Published private(set) var advertising = false
    @Published private(set) var connectedPeerNames: [String] = []
    @Published private(set) var lastError: String?

    var bluetoothPoweredOn: Bool { bluetooth.poweredOn }
    var bluetoothAdvertising: Bool { bluetooth.advertising }
    var bluetoothSubscribed: Bool { bluetooth.hasSubscribers }

    var onControlCommand: ((BuddyControlCommand) -> Void)?
    var onFocusRequest: ((MascotID) -> Void)?
    var onQuestionAnswer: ((String) -> Void)?

    private weak var appState: AppState?
    private let peerID: MCPeerID
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: ["protocol": "1"],
        serviceType: Self.serviceType
    )
    private var heartbeatTimer: Timer?
    private static let sequenceDefaultsKey = "AppleCompanion.lastSequence"
    /// Monotonic across app restarts (persisted): the phone drops any packet whose sequence
    /// is ≤ the last it saw, so a restart-to-0 would make it ignore the whole stream until the
    /// user restarts the phone app. Persisting keeps it strictly increasing (#4).
    private var sequence: UInt64 = UInt64(bitPattern: Int64(UserDefaults.standard.integer(forKey: AppleCompanionPublisher.sequenceDefaultsKey)))
    private let bluetooth = AppleCompanionBluetoothPeripheral()
    /// Watches the network path so a Wi-Fi/network drop+restore re-establishes the LAN link.
    /// MultipeerConnectivity does NOT resume advertising on its own after a path change, so
    /// without this the phone can't reconnect until the app is restarted (#4).
    private let pathMonitor = NWPathMonitor()
    private var pathMonitorStarted = false
    private var lastPathSatisfied: Bool?
    private var lastReconnectAt: Date?
    // Coalesce companion pushes: many concurrent agents fire hook events in bursts, and
    // pushing on every state change floods MultipeerConnectivity (pegged CPU). Cap to ~2/s.
    private var lastFlushAt: Date?
    private var trailingFlushScheduled = false
    private static let minFlushInterval: TimeInterval = 0.5
    /// While the companion is enabled, hold an activity assertion so macOS App Nap doesn't
    /// throttle our heartbeat timer / BLE updates and let the idle link drop.
    private var activityToken: NSObjectProtocol?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private override init() {
        let hostName = Host.current().localizedName ?? "Mac"
        let displayName = "CodeIsland \(hostName)"
        self.peerID = MCPeerID(displayName: String(displayName.prefix(63)))
        super.init()
        self.session.delegate = self
        self.advertiser.delegate = self
    }

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    func configure(enabled: Bool, heartbeatSeconds: Double) {
        self.enabled = enabled
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        guard enabled else {
            advertiser.stopAdvertisingPeer()
            bluetooth.configure(enabled: false)
            advertising = false
            connectedPeerNames = []
            session.disconnect()
            endActivity()
            return
        }

        lastError = nil
        beginActivity()
        startPathMonitorIfNeeded()
        advertiser.startAdvertisingPeer()
        bluetooth.configure(enabled: true)
        advertising = true
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: max(1.0, heartbeatSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flush(reason: "heartbeat")
            }
        }
        flush(reason: "enabled")
    }

    func notifyDirty() {
        flush(reason: "change")
    }

    private func beginActivity() {
        guard activityToken == nil else { return }
        // Prevent App Nap (keeps timers/BLE responsive) but still allow the Mac to sleep when idle.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "iPhone Buddy live link"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    func reconnect() {
        guard enabled else { return }
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        connectedPeerNames = []
        advertiser.startAdvertisingPeer()
        advertising = true
        bluetooth.configure(enabled: true)
        flush(reason: "reconnect")
    }

    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.handlePathUpdate(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.codeisland.companion.path"))
    }

    private func handlePathUpdate(satisfied: Bool) {
        let previous = lastPathSatisfied
        lastPathSatisfied = satisfied
        // Only act on a real transition back to "network available"; ignore the initial
        // callback (previous == nil) and debounce flapping so MC advertising doesn't churn.
        guard enabled, satisfied, previous == false else { return }
        // A path blip shouldn't tear down a healthy link — only re-establish if no peer is connected.
        guard session.connectedPeers.isEmpty else { return }
        let now = Date()
        if let last = lastReconnectAt, now.timeIntervalSince(last) < 3 { return }
        lastReconnectAt = now
        Self.log.info("network path restored — re-establishing companion link")
        reconnect()
    }

    private func flush(reason: String) {
        let now = Date()
        if let last = lastFlushAt, now.timeIntervalSince(last) < Self.minFlushInterval {
            // Within the rate-limit window — schedule a single trailing flush instead of
            // sending now, so a burst of state changes collapses into one push.
            guard !trailingFlushScheduled else { return }
            trailingFlushScheduled = true
            let delay = Self.minFlushInterval - now.timeIntervalSince(last)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay)) { [weak self] in
                self?.trailingFlushScheduled = false
                self?.performFlush(reason: "coalesced")
            }
            return
        }
        performFlush(reason: reason)
    }

    private func performFlush(reason: String) {
        lastFlushAt = Date()
        guard enabled, let appState else { return }
        sequence &+= 1
        UserDefaults.standard.set(Int64(bitPattern: sequence), forKey: Self.sequenceDefaultsKey)
        let payload = appState.appleCompanionStatePayload(sequence: sequence)

        bluetooth.publish(payload)

        guard !session.connectedPeers.isEmpty else { return }
        do {
            let data = try encoder.encode(payload)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            Self.log.debug("push(\(reason)): seq=\(payload.sequence) source=\(payload.source) status=\(payload.status.rawValue) peers=\(self.session.connectedPeers.count)")
        } catch {
            lastError = error.localizedDescription
            Self.log.error("push failed: \(error.localizedDescription)")
        }
    }

    private func handleCommand(_ command: AppleCompanionCommandPayload) {
        switch command.type {
        case .requestCurrentState:
            flush(reason: "requested")
        case .approveCurrentPermission:
            onControlCommand?(.approveCurrentPermission)
        case .denyCurrentPermission:
            onControlCommand?(.denyCurrentPermission)
        case .skipCurrentQuestion:
            onControlCommand?(.skipCurrentQuestion)
        case .answerQuestion:
            if let answer = command.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
               !answer.isEmpty {
                onQuestionAnswer?(answer)
            }
        case .focus:
            onFocusRequest?(MascotID(sourceName: command.source) ?? .claude)
        }
    }

    private func refreshConnectedPeers() {
        connectedPeerNames = session.connectedPeers.map(\.displayName).sorted()
    }
}

extension AppleCompanionPublisher: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            guard self.enabled else {
                invitationHandler(false, nil)
                return
            }
            Self.log.info("accepted invitation from \(peerID.displayName)")
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.advertising = false
            self.lastError = error.localizedDescription
            Self.log.error("advertising failed: \(error.localizedDescription)")
        }
    }
}

extension AppleCompanionPublisher: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.refreshConnectedPeers()
            switch state {
            case .connected:
                self.flush(reason: "peer-connected")
            case .notConnected:
                // Peer dropped. MC keeps advertising on its own, so only restart advertising
                // if it actually stopped — re-advertising on every disconnect can feed a
                // connect/disconnect storm (pegged CPU) when a peer link is flapping (#4).
                guard self.enabled, !self.advertising else { break }
                self.advertiser.startAdvertisingPeer()
                self.advertising = true
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            do {
                let command = try self.decoder.decode(AppleCompanionCommandPayload.self, from: data)
                self.handleCommand(command)
            } catch {
                self.lastError = "Ignored command from \(peerID.displayName): \(error.localizedDescription)"
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}
