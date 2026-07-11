import SwiftUI
import CodeIslandCore

/// Global aggregation board — every agent session across local + remote machines (R8).
///
/// "SENTINEL LANES": a portrait-native wall display for a dedicated vertical monitor.
/// The fixed top third answers "is anything on fire?" from across the room (aggregate glow
/// bar + KPI pills + a NEEDS-YOU alert band + a machine×agent matrix that never scrolls);
/// the scrollable body carries up-close density as attention-sorted per-machine LANES of
/// status-sized session cards (waiting = hero, running = medium glow card, idle = collapsed
/// chip). It is a pure read-only presentation over `appState.sessions` — no reducer or
/// business-logic change — reusing the app's existing glow palette + agent primitives.
///
/// Per-second liveness is scoped to leaf time labels (self-ticking `TickingDuration` /
/// `TickingIdle` / `WallClock`), so the heavy lane/KPI derivation and card re-diff only run
/// when `appState.sessions` actually changes — the right steady-state cost for an always-on wall.
struct DashboardView: View {
    @Bindable var appState: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One-shot green "done flash" nonce, bumped only when a session genuinely completes
    /// (successful idle count rises) — never on cancellation or session pruning.
    @State private var doneNonce = 0

    var body: some View {
        let lanes = buildLanes()
        let attention = attentionSessions()
        let counts = kpiCounts()
        let doneCount = appState.sessions.values.filter { $0.status == .idle && !$0.interrupted }.count

        ZStack(alignment: .top) {
            DashPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Fixed answer-bands (always visible, no scroll) ──
                VStack(spacing: 14) {
                    AggregateGlowHeader(
                        dominant: dominant(),
                        doneNonce: doneNonce,
                        machineCount: lanes.count,
                        agentCount: counts.agentSources,
                        liveCount: counts.run + counts.wait,
                        reduceMotion: reduceMotion
                    )
                    KPIPillRow(counts: counts, reduceMotion: reduceMotion)
                    if !attention.isEmpty {
                        NeedsYouBand(items: attention, reduceMotion: reduceMotion)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if lanes.count > 1 || appState.sessions.count > 3 {
                        StatusMatrix(lanes: lanes, reduceMotion: reduceMotion)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .animation(.easeInOut(duration: 0.3), value: attention.map(\.id))

                Rectangle().fill(DashPalette.hairline).frame(height: 1)

                // ── Scrollable machine lanes (up-close density) ──
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if appState.sessions.isEmpty {
                            EmptyStateView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else {
                            ForEach(lanes) { lane in
                                MachineLaneView(lane: lane, reduceMotion: reduceMotion)
                                    .id(lane.id)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.snappy(duration: 0.32), value: lanes.map(\.id))
                }
            }
        }
        .onChange(of: doneCount) { old, new in
            if new > old { doneNonce &+= 1 }
        }
    }

    // MARK: - Derivation

    private var sortedSessions: [(id: String, session: SessionSnapshot)] {
        appState.sessions
            .map { ($0.key, $0.value) }
            .sorted { $0.1.lastActivity > $1.1.lastActivity }
    }

    private func buildLanes() -> [DashLane] {
        var order: [String] = []
        var byKey: [String: DashLane] = [:]
        for (id, s) in sortedSessions {
            let g = AgentCatalog.machineGroup(for: s)
            if byKey[g.key] == nil {
                let isRemote = g.key != AgentCatalog.localMachineKey
                byKey[g.key] = DashLane(
                    key: g.key,
                    label: g.label,
                    isRemote: isRemote,
                    hostId: isRemote ? g.key : nil,
                    items: []
                )
                order.append(g.key)
            }
            byKey[g.key]?.items.append((id: id, session: s))
        }
        var lanes = order.compactMap { byKey[$0] }
        // Attention-first, then by active load, local pinned first on ties.
        lanes.sort { a, b in
            let aw = a.waitCount > 0, bw = b.waitCount > 0
            if aw != bw { return aw }
            if a.activeCount != b.activeCount { return a.activeCount > b.activeCount }
            if a.isRemote != b.isRemote { return !a.isRemote }
            return a.label < b.label
        }
        return lanes
    }

    /// Sessions that genuinely need a human: waiting for approval or a question, urgency-sorted.
    private func attentionSessions() -> [DashItem] {
        sortedSessions
            .filter { dashKind($0.session) == .waiting }
            .sorted { a, b in
                let pa = kindPriority(a.session), pb = kindPriority(b.session)
                if pa != pb { return pa < pb }
                return a.session.lastActivity > b.session.lastActivity
            }
            .map { DashItem(id: $0.id, session: $0.session) }
    }

    private func kpiCounts() -> KPICounts {
        var c = KPICounts()
        for s in appState.sessions.values {
            switch dashKind(s) {
            case .running: c.run += 1
            case .waiting: c.wait += 1
            case .idle:    c.idle += 1
            case .error:   c.err += 1
            }
        }
        c.agentSources = Set(appState.sessions.values.map { AgentCatalog.canonicalSource($0.source) }).count
        return c
    }

    /// Dominant fleet status driving the header glow: waiting > running > error > idle.
    private func dominant() -> DashStatus {
        var hasRunning = false, hasError = false
        for s in appState.sessions.values {
            switch dashKind(s) {
            case .waiting: return .waiting
            case .running: hasRunning = true
            case .error:   hasError = true
            case .idle:    break
            }
        }
        if hasRunning { return .running }
        if hasError { return .error }
        return .idle
    }
}

// MARK: - Models

/// Aggregate status counts driving the KPI pills + header census.
private struct KPICounts {
    var run = 0, wait = 0, idle = 0, err = 0
    var agentSources = 0
}

/// One session, wrapped so the id travels with the snapshot.
private struct DashItem: Identifiable {
    let id: String
    let session: SessionSnapshot
}

/// A machine group (local or one remote host) with its sessions.
private struct DashLane: Identifiable {
    let key: String
    let label: String
    let isRemote: Bool
    let hostId: String?
    var items: [(id: String, session: SessionSnapshot)]
    var id: String { key }

    var runCount: Int  { items.filter { dashKind($0.session) == .running }.count }
    var waitCount: Int { items.filter { dashKind($0.session) == .waiting }.count }
    var errCount: Int  { items.filter { dashKind($0.session) == .error }.count }
    var idleCount: Int { items.filter { dashKind($0.session) == .idle }.count }
    var activeCount: Int { runCount + waitCount }

    /// Items sorted for display: waiting, then interrupted, then running, then idle;
    /// most-recent first within a tier.
    var sortedItems: [(id: String, session: SessionSnapshot)] {
        items.sorted { a, b in
            let pa = kindPriority(a.session), pb = kindPriority(b.session)
            if pa != pb { return pa < pb }
            return a.session.lastActivity > b.session.lastActivity
        }
    }
}

// MARK: - Status vocabulary

private enum DashStatus { case running, waiting, idle, error }

private func dashKind(_ s: SessionSnapshot) -> DashStatus {
    if s.status == .idle && s.interrupted { return .error }
    switch s.status {
    case .running, .processing: return .running
    case .waitingApproval, .waitingQuestion: return .waiting
    case .idle: return .idle
    }
}

private func kindPriority(_ s: SessionSnapshot) -> Int {
    switch dashKind(s) {
    case .waiting: return 0
    case .error:   return 1
    case .running: return 2
    case .idle:    return 3
    }
}

private func dashColor(_ kind: DashStatus) -> Color {
    switch kind {
    case .running: return DashPalette.running
    case .waiting: return DashPalette.waiting
    case .error:   return DashPalette.error
    case .idle:    return DashPalette.idle
    }
}

private func dashGlyph(_ kind: DashStatus) -> String {
    switch kind {
    case .running: return "▶"
    case .waiting: return "◔"
    case .error:   return "✕"
    case .idle:    return "●"
    }
}

private func statusPillText(_ kind: DashStatus) -> String {
    let l = L10n.shared
    switch kind {
    case .running: return l["status_running"].uppercased()
    case .waiting: return l["status_waiting"].uppercased()
    case .idle:    return l["dashboard_idle"]
    case .error:   return l["dashboard_err"]
    }
}

// MARK: - Palette

private enum DashPalette {
    static let background = LinearGradient(
        colors: [Color(red: 0.075, green: 0.082, blue: 0.11), Color(red: 0.035, green: 0.039, blue: 0.055)],
        startPoint: .top, endPoint: .bottom
    )
    static let running = IslandGlowPalette.running       // #6E9FFF
    static let waiting = IslandGlowPalette.attention     // #FF9F0A
    static let done    = IslandGlowPalette.done          // #42E86B
    static let error   = Color(red: 1.0, green: 0.27, blue: 0.23)   // #FF453A
    static let idle    = Color(red: 0.55, green: 0.58, blue: 0.63)  // #8A8F9A
    static let cardFill = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.07)
}

// MARK: - Aggregate header

private struct AggregateGlowHeader: View {
    let dominant: DashStatus
    let doneNonce: Int
    let machineCount: Int
    let agentCount: Int
    let liveCount: Int
    let reduceMotion: Bool
    @ObservedObject private var l10n = L10n.shared
    @State private var pulse = false

    private var barColor: Color {
        switch dominant {
        case .waiting: return DashPalette.waiting
        case .running: return DashPalette.running
        case .error:   return DashPalette.error.opacity(0.7)
        case .idle:    return DashPalette.done.opacity(0.55)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(barColor).frame(width: 9, height: 9)
                    .shadow(color: barColor.opacity(0.8), radius: 5)
                Text("CODEISLAND")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("· SENTINEL")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 8)
                WallClock()
            }

            // Signature glowing status bar — pulses orange while anything is waiting.
            Capsule()
                .fill(LinearGradient(colors: [barColor.opacity(0.9), barColor.opacity(0.55)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
                .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
                .modifier(GlowShadow(color: barColor,
                                     level: dominant == .waiting && !reduceMotion ? (pulse ? 1.0 : 0.5)
                                          : (dominant == .idle ? 0.35 : 0.85)))
                .modifier(DoneFlash(nonce: doneNonce))

            Text(census)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
        .onAppear { updatePulse(dominant == .waiting) }
        .onChange(of: dominant) { _, d in updatePulse(d == .waiting) }
    }

    private func updatePulse(_ on: Bool) {
        guard !reduceMotion else { pulse = false; return }
        if on {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }

    private var census: String {
        let m = "\(machineCount) \(machineCount == 1 ? l10n["dashboard_machine"] : l10n["dashboard_machines"])"
        let a = "\(agentCount) \(l10n["dashboard_agents"])"
        let live = "\(liveCount) \(l10n["dashboard_live"])"
        return "\(m) · \(a) · \(live)"
    }
}

/// Live HH:mm:ss wall clock (self-ticking; does not re-diff the board).
private struct WallClock: View {
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.formatter.string(from: context.date))
                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - KPI pills

private struct KPIPillRow: View {
    let counts: KPICounts
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 10) {
            KPIPill(value: counts.run, label: L10n.shared["dashboard_run"], glyph: "▶",
                    color: DashPalette.running, pulsing: false, reduceMotion: reduceMotion)
            KPIPill(value: counts.wait, label: L10n.shared["dashboard_wait"], glyph: "◔",
                    color: DashPalette.waiting, pulsing: counts.wait > 0, reduceMotion: reduceMotion)
            KPIPill(value: counts.idle, label: L10n.shared["dashboard_idle"], glyph: "●",
                    color: DashPalette.idle, pulsing: false, reduceMotion: reduceMotion)
            KPIPill(value: counts.err, label: L10n.shared["dashboard_err"], glyph: "✕",
                    color: DashPalette.error, pulsing: false, reduceMotion: reduceMotion)
        }
    }
}

private struct KPIPill: View {
    let value: Int
    let label: String
    let glyph: String
    let color: Color
    let pulsing: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    private var shouldPulse: Bool { pulsing && value > 0 }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(value > 0 ? color : .white.opacity(0.35))
            HStack(spacing: 4) {
                Text(glyph).font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(value > 0 ? color.opacity(0.9) : .white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(value > 0 ? 0.10 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(value > 0 ? 0.28 : 0.08), lineWidth: 1)
        )
        .modifier(GlowShadow(color: shouldPulse ? color : nil,
                             level: reduceMotion ? 0.6 : (pulse ? 0.9 : 0.4)))
        .onAppear { updatePulse(shouldPulse) }
        .onChange(of: shouldPulse) { _, on in updatePulse(on) }
    }

    private func updatePulse(_ on: Bool) {
        guard !reduceMotion else { pulse = false; return }
        if on {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }
}

// MARK: - NEEDS-YOU band

private struct NeedsYouBand: View {
    let items: [DashItem]
    let reduceMotion: Bool
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("⚠").font(.system(size: 12))
                Text("\(items.count) \(l10n["dashboard_needs_you"])")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(DashPalette.waiting)
                    .tracking(1)
                Spacer()
            }
            ForEach(items.prefix(5)) { item in
                AlertCard(item: item, reduceMotion: reduceMotion)
            }
            if items.count > 5 {
                Text("+\(items.count - 5)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct AlertCard: View {
    let item: DashItem
    let reduceMotion: Bool
    @ObservedObject private var l10n = L10n.shared

    private var kind: DashStatus { dashKind(item.session) }
    private var accent: Color { dashColor(kind) }

    private var verb: String {
        switch item.session.status {
        case .waitingApproval: return l10n["dashboard_approve"]
        case .waitingQuestion: return l10n["dashboard_ask"]
        default:               return l10n["dashboard_stopped"]
        }
    }

    private var detail: String {
        if let tool = item.session.currentTool {
            if let d = item.session.toolDescription, !d.isEmpty { return "\(tool)(\(d))" }
            return tool
        }
        return item.session.toolDescription ?? item.session.lastAssistantMessage ?? "—"
    }

    private var machineLabel: String { AgentCatalog.machineGroup(for: item.session).label }

    var body: some View {
        GlowCard(accent: AgentCatalog.brandColor(source: item.session.source),
                 glow: accent, pulsing: kind == .waiting, reduceMotion: reduceMotion,
                 cornerRadius: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(dashGlyph(kind)).font(.system(size: 12)).foregroundStyle(accent)
                    Text(machineLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    AgentAppIcon(source: item.session.source, size: 16)
                    Text(item.session.sessionLabel ?? item.session.projectDisplayName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    TickingDuration(since: item.session.lastActivity, color: accent, size: 11)
                }
                HStack(alignment: .top, spacing: 7) {
                    Text(verb)
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(accent))
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Machine × agent matrix

private struct StatusMatrix: View {
    let lanes: [DashLane]
    let reduceMotion: Bool
    @ObservedObject private var remoteManager = RemoteManager.shared
    @ObservedObject private var l10n = L10n.shared

    /// Sources present across the fleet, most-common first.
    private var columns: [String] {
        var counts: [String: Int] = [:]
        for lane in lanes {
            for item in lane.items {
                counts[AgentCatalog.canonicalSource(item.session.source), default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    var body: some View {
        let cols = columns
        let shown = Array(cols.prefix(6))
        let overflow = Array(cols.dropFirst(6))
        let maxLoad = max(1, lanes.map(\.activeCount).max() ?? 1)

        VStack(alignment: .leading, spacing: 6) {
            Text(l10n["dashboard_fleet"])
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4)).tracking(1.5)

            Grid(alignment: .center, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: 2, height: 1).gridColumnAlignment(.leading)
                    ForEach(shown, id: \.self) { src in
                        Text(sourceCode(src))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    if !overflow.isEmpty {
                        Text("+\(overflow.count)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Text(l10n["dashboard_load"]).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                    Text(l10n["dashboard_count"]).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                }
                ForEach(lanes) { lane in
                    GridRow {
                        HStack(spacing: 5) {
                            HostDot(state: hostState(lane))
                            Text(lane.label)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .frame(minWidth: 92, alignment: .leading)
                        .gridColumnAlignment(.leading)

                        ForEach(shown, id: \.self) { src in
                            MatrixCell(kind: aggregateKind(lane: lane, sources: [src]), reduceMotion: reduceMotion)
                        }
                        if !overflow.isEmpty {
                            MatrixCell(kind: aggregateKind(lane: lane, sources: overflow), reduceMotion: reduceMotion)
                        }
                        MiniLoadBar(value: lane.activeCount, max: maxLoad)
                        Text("\(lane.items.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DashPalette.hairline, lineWidth: 1))
    }

    private func aggregateKind(lane: DashLane, sources: [String]) -> DashStatus? {
        let set = Set(sources)
        let matching = lane.items.filter { set.contains(AgentCatalog.canonicalSource($0.session.source)) }
        guard !matching.isEmpty else { return nil }
        return matching.map { dashKind($0.session) }.min(by: { rank($0) < rank($1) })
    }

    private func rank(_ k: DashStatus) -> Int {
        switch k { case .waiting: return 0; case .error: return 1; case .running: return 2; case .idle: return 3 }
    }

    private func hostState(_ lane: DashLane) -> HostState {
        guard lane.isRemote, let id = lane.hostId else { return .local }
        switch remoteManager.connectionStatus[id] {
        case .connected:  return .connected
        case .connecting: return .connecting
        case .failed:     return .failed
        default:          return .disconnected
        }
    }
}

private struct MatrixCell: View {
    let kind: DashStatus?
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        Group {
            if let kind {
                Text(dashGlyph(kind))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(dashColor(kind))
                    .opacity(kind == .waiting && !reduceMotion ? (pulse ? 1.0 : 0.45) : 1.0)
            } else {
                Text("·").font(.system(size: 12)).foregroundStyle(.white.opacity(0.15))
            }
        }
        .frame(minWidth: 20)
        .onAppear { updatePulse(kind == .waiting) }
        .onChange(of: kind) { _, k in updatePulse(k == .waiting) }
    }

    private func updatePulse(_ on: Bool) {
        guard !reduceMotion else { pulse = false; return }
        if on {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }
}

private enum HostState { case local, connected, connecting, disconnected, failed }

private struct HostDot: View {
    let state: HostState
    private var color: Color {
        switch state {
        case .local, .connected: return DashPalette.done
        case .connecting:        return DashPalette.waiting
        case .failed:            return DashPalette.error
        case .disconnected:      return DashPalette.idle.opacity(0.6)
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.7), radius: 3)
    }
}

private struct MiniLoadBar: View {
    let value: Int
    let max: Int
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(DashPalette.running)
                    .frame(width: geo.size.width * CGFloat(value) / CGFloat(Swift.max(1, max)))
            }
        }
        .frame(width: 42, height: 5)
    }
}

// MARK: - Machine lane

private struct MachineLaneView: View {
    let lane: DashLane
    let reduceMotion: Bool
    @ObservedObject private var remoteManager = RemoteManager.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let sorted = lane.sortedItems
        // Only waiting/running get full cards; idle AND interrupted (error) fold into the chip row,
        // honoring the "always collapse resting sessions" choice. A waiting session still shows in
        // the NEEDS-YOU band above; interrupted sessions read as a ✕ chip here.
        let active = sorted.filter { let k = dashKind($0.session); return k == .waiting || k == .running }
        let resting = sorted.filter { let k = dashKind($0.session); return k == .idle || k == .error }

        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(active, id: \.id) { entry in
                SessionVitalsCard(session: entry.session, reduceMotion: reduceMotion)
                    .id(entry.id)
            }
            if !resting.isEmpty {
                IdleChipRow(items: resting)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(laneAccent).frame(width: 4, height: 22)
            Text(lane.label)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            DashTag(lane.isRemote ? l10n["dashboard_remote"] : l10n["dashboard_local"],
                    color: lane.isRemote ? DashPalette.running : DashPalette.idle)
            if lane.isRemote { sshChip }
            Spacer(minLength: 8)
            StatusMeter(run: lane.runCount, wait: lane.waitCount, err: lane.errCount, idle: lane.idleCount)
                .frame(width: 90)
            Text("\(lane.items.count) \(l10n["dashboard_sessions"])")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var laneAccent: Color {
        if lane.waitCount > 0 { return DashPalette.waiting }
        if lane.runCount > 0 { return DashPalette.running }
        if lane.errCount > 0 { return DashPalette.error }
        return DashPalette.idle.opacity(0.5)
    }

    @ViewBuilder private var sshChip: some View {
        if let id = lane.hostId {
            switch remoteManager.connectionStatus[id] {
            case .connected:  DashTag(l10n["dashboard_ssh_ok"], color: DashPalette.done)
            case .connecting: DashTag(l10n["dashboard_ssh_connecting"], color: DashPalette.waiting)
            case .failed:     DashTag(l10n["dashboard_ssh_failed"], color: DashPalette.error)
            default:          EmptyView()
            }
        }
    }
}

private struct StatusMeter: View {
    let run: Int
    let wait: Int
    let err: Int
    let idle: Int
    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(1, run + wait + err + idle))
            let w = geo.size.width
            HStack(spacing: 1.5) {
                if run > 0 { seg(DashPalette.running, w * CGFloat(run) / total) }
                if wait > 0 { seg(DashPalette.waiting, w * CGFloat(wait) / total) }
                if err > 0 { seg(DashPalette.error, w * CGFloat(err) / total) }
                if idle > 0 { seg(DashPalette.idle.opacity(0.4), w * CGFloat(idle) / total) }
            }
        }
        .frame(height: 5)
    }
    private func seg(_ c: Color, _ width: CGFloat) -> some View {
        Capsule().fill(c).frame(width: max(2, width - 1.5))
    }
}

// MARK: - Session vitals card

private struct SessionVitalsCard: View {
    let session: SessionSnapshot
    let reduceMotion: Bool
    @ObservedObject private var l10n = L10n.shared

    private var kind: DashStatus { dashKind(session) }

    var body: some View {
        GlowCard(accent: AgentCatalog.brandColor(source: session.source),
                 glow: kind == .running ? DashPalette.running : (kind == .waiting ? DashPalette.waiting : nil),
                 pulsing: kind == .waiting, reduceMotion: reduceMotion, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                // Title row
                HStack(spacing: 8) {
                    AgentAppIcon(source: session.source, size: 22)
                    Text(session.sessionLabel ?? session.projectDisplayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    StatusPill(text: statusPillText(kind), color: dashColor(kind))
                    if let m = session.shortModelName {
                        DashTag(m, color: DashPalette.running.opacity(0.85))
                    }
                    TickingDuration(since: session.startTime, color: .white.opacity(0.6), size: 12)
                }

                // Live activity row
                if let tool = session.currentTool {
                    HStack(spacing: 6) {
                        Text(tool)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DashPalette.running)
                        if let d = session.toolDescription, !d.isEmpty {
                            Text("· \(d)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if kind == .running { BrailleSpinner(color: DashPalette.running, reduceMotion: reduceMotion) }
                    }
                }

                // Metrics row — wraps so nothing clips at narrow portrait width.
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    ContextMeter(percent: session.contextWindowPercent, used: session.contextTokensUsed)
                    if session.totalToolCallCount > 0 {
                        MetricLabel(text: "\(session.totalToolCallCount) \(l10n["dashboard_tools"])")
                    }
                    if session.activeSubagentCount > 0 {
                        MetricLabel(text: "⑂\(session.activeSubagentCount) \(l10n["dashboard_subs"])", color: Color(red: 0.65, green: 0.55, blue: 0.95))
                    }
                    if session.lastInputTokens != nil || session.lastOutputTokens != nil {
                        MetricLabel(text: "↑\(SessionSnapshot.compactTokens(session.lastInputTokens ?? 0)) ↓\(SessionSnapshot.compactTokens(session.lastOutputTokens ?? 0))",
                                    color: .white.opacity(0.55))
                    }
                    if let term = session.terminalName {
                        DashTag(term, color: .white.opacity(0.45))
                    }
                    if session.isYoloMode == true {
                        DashTag("YOLO", color: DashPalette.error)
                    }
                }

                // Last prompt
                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    Text("↳ \(prompt)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }
}

private struct MetricLabel: View {
    let text: String
    var color: Color = .white.opacity(0.6)
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

private struct ContextMeter: View {
    let percent: Int?
    let used: Int?

    private var color: Color {
        guard let p = percent else { return DashPalette.done }
        if p >= 85 { return DashPalette.error }
        if p >= 70 { return DashPalette.waiting }
        return DashPalette.done
    }

    var body: some View {
        if let p = percent {
            HStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(width: 46, height: 5)
                    Capsule().fill(color)
                        .frame(width: 46 * CGFloat(p) / 100.0, height: 5)
                }
                Text("\(p)% ctx")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
            }
        } else if let u = used {
            // No window limit known — show the raw context size, no misleadingly-empty bar.
            MetricLabel(text: "\(SessionSnapshot.compactTokens(u)) ctx", color: DashPalette.done)
        }
    }
}

// MARK: - Idle chips

private struct IdleChipRow: View {
    let items: [(id: String, session: SessionSnapshot)]
    @ObservedObject private var l10n = L10n.shared

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.id) { entry in
                chip(entry.session)
            }
        }
        .padding(.top, 2)
    }

    private func chip(_ s: SessionSnapshot) -> some View {
        let interrupted = s.interrupted
        let done = s.toolHistory.last?.success
        return HStack(spacing: 6) {
            AgentAppIcon(source: s.source, size: 14).opacity(0.7)
            Text(s.sessionLabel ?? s.projectDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 2)
            HStack(spacing: 2) {
                Text(l10n["dashboard_idle_label"])
                TickingIdle(since: s.lastActivity)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
            if interrupted {
                Text("✕").font(.system(size: 10)).foregroundStyle(DashPalette.error.opacity(0.8))
            } else if done == true {
                Text("✓").font(.system(size: 10)).foregroundStyle(DashPalette.done.opacity(0.7))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashPalette.hairline, lineWidth: 0.5))
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    @ObservedObject private var l10n = L10n.shared
    var body: some View {
        VStack(spacing: 16) {
            MascotView(source: "claude", status: .idle, size: 72)
                .opacity(0.7)
            Text(l10n["dashboard_all_quiet"])
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(DashPalette.done.opacity(0.7))
                .tracking(2)
            Text(l10n["dashboard_empty"])
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

// MARK: - Reusable chrome

/// Lifted-glass card with an optional colored glow ring (the app's signature two-stop
/// drop-shadow) and a brand-colored left accent stripe. The waiting pulse is driven by state
/// changes (not just onAppear) so a card that transitions into `waiting` in place still pulses.
private struct GlowCard<Content: View>: View {
    let accent: Color
    let glow: Color?
    let pulsing: Bool
    let reduceMotion: Bool
    var cornerRadius: CGFloat = 14
    @ViewBuilder var content: () -> Content
    @State private var pulse = false

    var body: some View {
        content()
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(DashPalette.cardFill))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(GlowShadow(color: glow, level: pulsing && !reduceMotion ? (pulse ? 1.0 : 0.5) : 0.7))
            .onAppear { updatePulse(pulsing) }
            .onChange(of: pulsing) { _, on in updatePulse(on) }
    }

    private func updatePulse(_ on: Bool) {
        guard !reduceMotion else { pulse = false; return }
        if on {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }
}

/// Two-stop colored drop-shadow "glow", matching the notch island aesthetic. `nil` color = no glow.
private struct GlowShadow: ViewModifier {
    let color: Color?
    var level: Double = 0.7
    func body(content: Content) -> some View {
        if let color {
            content
                .shadow(color: color.opacity(0.45 * level), radius: 22)
                .shadow(color: color.opacity(0.8 * level), radius: 8)
        } else {
            content
        }
    }
}

/// One-shot green flash keyed off a nonce (fires only on genuine task completion).
private struct DoneFlash: ViewModifier {
    let nonce: Int
    @State private var flash: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .shadow(color: DashPalette.done.opacity(flash), radius: 16)
            .onChange(of: nonce) { _, _ in
                guard !reduceMotion else { return }
                flash = 0.85
                withAnimation(.easeOut(duration: 1.1)) { flash = 0 }
            }
    }
}

private struct DashTag: View {
    let text: String
    var color: Color = .white.opacity(0.65)
    init(_ text: String, color: Color = .white.opacity(0.65)) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.14)))
    }
}

/// Animated braille spinner (its own fast timeline so the board never re-diffs for it).
private struct BrailleSpinner: View {
    let color: Color
    let reduceMotion: Bool
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    var body: some View {
        if reduceMotion {
            Text("⠿").font(.system(size: 12)).foregroundStyle(color)
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let i = Int(context.date.timeIntervalSinceReferenceDate * 10) % Self.frames.count
                Text(Self.frames[i]).font(.system(size: 12)).foregroundStyle(color)
            }
        }
    }
}

/// Live m:ss / h:mm:ss elapsed label — self-ticking so only this Text re-renders each second.
private struct TickingDuration: View {
    let since: Date
    var color: Color = .white.opacity(0.6)
    var size: CGFloat = 12
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(fmtDuration(context.date.timeIntervalSince(since)))
                .font(.system(size: size, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

/// Live coarse "idle for" label — self-ticking at a relaxed cadence (idle grows slowly).
private struct TickingIdle: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(fmtIdle(context.date.timeIntervalSince(since)))
        }
    }
}

// MARK: - Flow layout

/// A left-to-right wrapping layout for chip rows: items flow onto new lines instead of clipping.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width = maxWidth.isFinite ? min(maxWidth, widest) : widest
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0; rowHeight = 0
            }
            sv.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                     anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Helpers

private func sourceCode(_ canonical: String) -> String {
    let map: [String: String] = [
        "claude": "cla", "codex": "cdx", "gemini": "gem", "google-antigravity": "gag",
        "cursor": "cur", "cursor-cli": "cur", "copilot": "cop",
        "trae": "tra", "traecn": "tra", "traecli": "tra",
        "qoder": "qod", "qoder-cli": "qod", "droid": "fac",
        "codebuddy": "bud", "codybuddycn": "bud", "stepfun": "stp",
        "opencode": "opc", "antigravity": "ant", "workbuddy": "wor",
        "hermes": "her", "qwen": "qwn", "kimi": "kim", "pi": "pi",
        "kiro": "kir", "cline": "cln",
    ]
    if let m = map[canonical] { return m }
    return String(canonical.prefix(3))
}

/// m:ss for < 1h, h:mm:ss beyond.
private func fmtDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

/// Coarse "idle for" formatting: <1m / 12m / 3h / 2d.
private func fmtIdle(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 60 { return "<1m" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
