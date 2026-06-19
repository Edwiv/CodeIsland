import Foundation
@preconcurrency import CoreBluetooth
import os
import CodeIslandCore

@MainActor
final class AppleCompanionBluetoothPeripheral: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "6D951BA3-8F41-4C45-9D8A-12085E0D7A10")
    static let notifyCharacteristicUUID = CBUUID(string: "25C1B67B-E903-4A0C-8A78-3EE8AB7317B7")

    private static let log = Logger(subsystem: "com.codeisland", category: "apple-companion-ble")
    private static let maxChunkPayloadBytes = 120
    /// How often to verify advertising is alive and nudge a keep-alive to subscribers. Keeps the
    /// link warm independent of the publisher heartbeat (which App Nap can throttle).
    private static let watchdogInterval: TimeInterval = 4

    @Published private(set) var poweredOn = false
    @Published private(set) var advertising = false
    @Published private(set) var hasSubscribers = false
    @Published private(set) var lastError: String?

    private lazy var peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var latestChunks: [Data] = []
    private var pendingChunks: [Data] = []
    private var enabled = false
    /// True once our service is registered with the system. We add it exactly once per BT
    /// power cycle — rebuilding it would disconnect a subscribed central (the old instability).
    private var serviceAdded = false
    private var watchdog: Timer?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func configure(enabled: Bool) {
        self.enabled = enabled

        guard enabled else {
            stopWatchdog()
            peripheralManager.stopAdvertising()
            peripheralManager.removeAllServices()
            serviceAdded = false
            advertising = false
            hasSubscribers = false
            pendingChunks = []
            latestChunks = []
            return
        }

        _ = peripheralManager
        // Idempotent: if the service is already up, just make sure we're advertising — do NOT
        // tear it down (that would drop a connected phone). Only build when missing.
        ensureServiceAndAdvertising()
        startWatchdog()
    }

    func publish(_ payload: AppleCompanionStatePayload) {
        guard enabled else { return }

        do {
            let summary = AppleCompanionBluetoothSummary(payload: payload)
            let data = try encoder.encode(summary)
            latestChunks = Self.makeChunks(sequence: payload.sequence, data: data)
            lastError = nil

            if hasSubscribers {
                sendLatestChunks()
            }
        } catch {
            lastError = error.localizedDescription
            Self.log.error("failed to encode BLE summary: \(error.localizedDescription)")
        }
    }

    // MARK: - Service / advertising lifecycle

    /// Bring the peripheral to the desired running state without disturbing an existing,
    /// healthy service+advertisement. Safe to call repeatedly.
    private func ensureServiceAndAdvertising() {
        guard enabled, peripheralManager.state == .poweredOn else { return }
        if serviceAdded {
            startAdvertisingIfReady()
        } else {
            addServiceFresh()
        }
    }

    /// Register the GATT service from scratch. Only call when `serviceAdded == false`
    /// (no service yet, or the BT stack was reset) — advertising restarts in `didAdd`.
    private func addServiceFresh() {
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        advertising = false
        serviceAdded = false

        let characteristic = CBMutableCharacteristic(
            type: Self.notifyCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        notifyCharacteristic = characteristic
        peripheralManager.add(service)
    }

    private func startAdvertisingIfReady() {
        guard enabled, poweredOn, serviceAdded, !advertising else { return }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "CodeIsland"
        ])
        advertising = true
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        // Run in .common mode so it still fires while menus/tracking loops are active.
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Self-heal: re-add the service if the stack lost it, restart advertising if it stopped,
    /// and re-push the latest state to keep a subscribed link from going idle/stale.
    private func watchdogTick() {
        guard enabled, poweredOn else { return }
        if !serviceAdded {
            addServiceFresh()
        } else if !advertising {
            startAdvertisingIfReady()
        } else if hasSubscribers, !latestChunks.isEmpty {
            sendLatestChunks()
        }
    }

    private func sendLatestChunks() {
        pendingChunks = latestChunks
        drainPendingChunks()
    }

    private func drainPendingChunks() {
        guard let notifyCharacteristic, hasSubscribers else { return }

        while !pendingChunks.isEmpty {
            let chunk = pendingChunks[0]
            guard peripheralManager.updateValue(chunk, for: notifyCharacteristic, onSubscribedCentrals: nil) else {
                return
            }
            pendingChunks.removeFirst()
        }
    }

    private static func makeChunks(sequence: UInt64, data: Data) -> [Data] {
        let chunkSize = maxChunkPayloadBytes
        let total = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))

        return (0..<total).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, data.count)
            let body = data.subdata(in: start..<end)

            var chunk = Data()
            chunk.append(0x43)
            chunk.append(0x49)
            chunk.append(0x01)
            chunk.appendUInt64(sequence)
            chunk.appendUInt16(UInt16(index))
            chunk.appendUInt16(UInt16(total))
            chunk.append(body)
            return chunk
        }
    }
}

extension AppleCompanionBluetoothPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                self.poweredOn = true
                self.lastError = nil
                // A fresh power-on means the stack dropped any previous service.
                self.serviceAdded = false
                self.advertising = false
                if self.enabled { self.ensureServiceAndAdvertising() }
            case .poweredOff:
                self.poweredOn = false
                self.advertising = false
                self.hasSubscribers = false
                self.serviceAdded = false
                self.lastError = "蓝牙已关闭"
            case .unauthorized:
                self.poweredOn = false
                self.advertising = false
                self.serviceAdded = false
                self.lastError = "蓝牙权限未授权"
            case .unsupported:
                self.poweredOn = false
                self.advertising = false
                self.serviceAdded = false
                self.lastError = "这台 Mac 不支持蓝牙"
            case .resetting:
                self.poweredOn = false
                self.advertising = false
                self.hasSubscribers = false
                self.serviceAdded = false
                self.lastError = "蓝牙正在重置"
            case .unknown:
                self.poweredOn = false
                self.advertising = false
            @unknown default:
                self.poweredOn = false
                self.advertising = false
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                self.serviceAdded = false
                self.lastError = error.localizedDescription
                Self.log.error("failed to add BLE service: \(error.localizedDescription)")
                return
            }
            self.serviceAdded = true
            self.startAdvertisingIfReady()
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error {
                self.advertising = false
                self.lastError = error.localizedDescription
                Self.log.error("failed to advertise BLE service: \(error.localizedDescription)")
                return
            }

            self.advertising = true
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            self.hasSubscribers = true
            self.sendLatestChunks()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            self.hasSubscribers = false
            self.pendingChunks = []
            // Keep the Mac discoverable so the phone can reconnect after a drop.
            self.startAdvertisingIfReady()
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            self.drainPendingChunks()
        }
    }
}

private struct AppleCompanionBluetoothSummary: Codable {
    struct SessionSummary: Codable {
        let sessionId: String?
        let source: String
        let status: String
        let toolName: String?
        let workspaceName: String?
        let message: String?
        let updatedAt: Date
    }

    let version: Int
    let sequence: UInt64
    let sessionId: String?
    let source: String
    let status: String
    let toolName: String?
    let workspaceName: String?
    let message: String?
    let pendingAction: String?
    let questionHeader: String?
    let questionText: String?
    let sessions: [SessionSummary]
    let updatedAt: Date

    init(payload: AppleCompanionStatePayload) {
        version = 1
        sequence = payload.sequence
        sessionId = payload.sessionId.map { Self.truncate($0, limit: 96) }
        source = payload.source
        status = payload.status.rawValue
        toolName = payload.toolName.map { Self.truncate($0, limit: 64) }
        workspaceName = payload.workspaceName.map { Self.truncate($0, limit: 64) }
        message = payload.messages.last.map { Self.truncate($0.text, limit: 220) }
        pendingAction = payload.pendingAction?.rawValue
        questionHeader = payload.question?.header.map { Self.truncate($0, limit: 40) }
        questionText = payload.question.map { Self.truncate($0.question, limit: 180) }
        sessions = payload.sessions.prefix(5).map {
            SessionSummary(
                sessionId: $0.sessionId.map { Self.truncate($0, limit: 96) },
                source: $0.source,
                status: $0.status.rawValue,
                toolName: $0.toolName.map { Self.truncate($0, limit: 48) },
                workspaceName: $0.workspaceName.map { Self.truncate($0, limit: 48) },
                message: $0.message.map { Self.truncate($0, limit: 120) },
                updatedAt: $0.updatedAt
            )
        }
        updatedAt = payload.updatedAt
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
