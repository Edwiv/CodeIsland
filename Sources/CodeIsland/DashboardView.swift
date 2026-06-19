import SwiftUI
import CodeIslandCore

/// Global aggregation/management page: every agent session across local + remote
/// machines, grouped and inspectable (R8). Port of AgentIsland's MainApp.
struct DashboardView: View {
    @Bindable var appState: AppState
    @ObservedObject private var l10n = L10n.shared

    enum Grouping: String, CaseIterable, Identifiable {
        case machine, cli, status, project
        var id: String { rawValue }
        var label: String {
            switch self {
            case .machine: return L10n.shared["dashboard_group_machine"]
            case .cli:     return L10n.shared["dashboard_group_cli"]
            case .status:  return L10n.shared["dashboard_group_status"]
            case .project: return L10n.shared["dashboard_group_project"]
            }
        }
    }

    @State private var grouping: Grouping = .machine
    @State private var selectedId: String?

    private var sortedSessions: [(id: String, session: SessionSnapshot)] {
        appState.sessions
            .map { ($0.key, $0.value) }
            .sorted { $0.1.lastActivity > $1.1.lastActivity }
    }

    private var groups: [(key: String, label: String, items: [(id: String, session: SessionSnapshot)])] {
        var order: [String] = []
        var byKey: [String: (label: String, items: [(String, SessionSnapshot)])] = [:]
        for (id, s) in sortedSessions {
            let g = groupKey(for: s)
            if byKey[g.key] == nil { byKey[g.key] = (g.label, []); order.append(g.key) }
            byKey[g.key]?.items.append((id, s))
        }
        return order.compactMap { key in
            guard let entry = byKey[key] else { return nil }
            return (key, entry.label, entry.items.map { (id: $0.0, session: $0.1) })
        }
    }

    private func groupKey(for s: SessionSnapshot) -> (key: String, label: String) {
        switch grouping {
        case .machine:
            return AgentCatalog.machineGroup(for: s)
        case .cli:
            return (s.source, s.sourceLabel)
        case .status:
            return (statusKey(s.status), statusLabel(s.status))
        case .project:
            let name = s.projectDisplayName
            return (s.cwd ?? name, name)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                sidebar
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { selectInitial() }
    }

    // MARK: - Header + stats

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n["dashboard_title"])
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                StatTile(value: runningCount, label: l10n["status_running"], color: IslandGlowPalette.running)
                StatTile(value: waitingCount, label: l10n["status_waiting"], color: IslandGlowPalette.attention)
                StatTile(value: machineCount, label: l10n["dashboard_machines"], color: Color(red: 0.56, green: 0.63, blue: 1.0))
                StatTile(value: agentCount, label: l10n["dashboard_agents"], color: IslandGlowPalette.done)
            }

            Picker("", selection: $grouping) {
                ForEach(Grouping.allCases) { g in Text(g.label).tag(g) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(14)
    }

    private var runningCount: Int { appState.sessions.values.filter { $0.status == .running }.count }
    private var waitingCount: Int {
        appState.sessions.values.filter { $0.status == .waitingApproval || $0.status == .waitingQuestion }.count
    }
    private var machineCount: Int {
        Set(appState.sessions.values.map { AgentCatalog.machineGroup(for: $0).key }).count
    }
    private var agentCount: Int { Set(appState.sessions.values.map { $0.source }).count }

    // MARK: - Sidebar list

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if appState.sessions.isEmpty {
                    Text(l10n["dashboard_empty"])
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(groups, id: \.key) { group in
                        HStack {
                            Text(group.label.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(group.items.count)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                        ForEach(group.items, id: \.id) { item in
                            DashboardRow(
                                session: item.session,
                                selected: selectedId == item.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { selectedId = item.id }
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedId, let session = appState.sessions[id] {
            DashboardDetail(appState: appState, sessionId: id, session: session)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(l10n["dashboard_select"])
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectInitial() {
        if let id = selectedId, appState.sessions[id] != nil { return }
        selectedId = sortedSessions.first(where: {
            $0.session.status == .waitingApproval || $0.session.status == .waitingQuestion
        })?.id ?? sortedSessions.first?.id
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let value: Int
    let label: String
    let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Sidebar row

private struct DashboardRow: View {
    let session: SessionSnapshot
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            AgentAppIcon(source: session.source, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.sessionLabel ?? session.projectDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle().fill(statusColor(session.status)).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .padding(.horizontal, 6)
    }

    private var subtitle: String {
        session.currentTool ?? session.toolDescription ?? (session.subtitle ?? statusLabel(session.status))
    }
}

// MARK: - Detail pane

private struct DashboardDetail: View {
    @Bindable var appState: AppState
    @ObservedObject private var l10n = L10n.shared
    let sessionId: String
    let session: SessionSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    AgentAppIcon(source: session.source, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.sessionLabel ?? session.projectDisplayName)
                            .font(.system(size: 16, weight: .bold))
                        Text(session.sourceLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        TerminalActivator.activate(session: session, sessionId: sessionId)
                    } label: {
                        Label(l10n["dashboard_jump"], systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                }

                metaGrid

                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    section(l10n["dashboard_last_prompt"]) {
                        Text(prompt).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
                if let reply = session.lastAssistantMessage, !reply.isEmpty {
                    section(l10n["dashboard_last_reply"]) {
                        Text(reply).font(.system(size: 12)).textSelection(.enabled)
                    }
                }

                if !session.toolHistory.isEmpty {
                    section(l10n["dashboard_recent_tools"]) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(session.toolHistory.suffix(12).enumerated()), id: \.offset) { _, entry in
                                HStack(spacing: 6) {
                                    Image(systemName: entry.success ? "checkmark.circle" : "xmark.circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(entry.success ? .green : .red)
                                    Text(entry.tool).font(.system(size: 11, weight: .medium, design: .monospaced))
                                    if let d = entry.description, !d.isEmpty {
                                        Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metaGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            metaRow(l10n["dashboard_machine"], AgentCatalog.machineGroup(for: session).label)
            if let cwd = session.cwd { metaRow(l10n["dashboard_path"], cwd) }
            if let model = session.model { metaRow(l10n["dashboard_model"], model) }
            metaRow(l10n["dashboard_status"], statusLabel(session.status))
            if let term = session.terminalName { metaRow(l10n["dashboard_terminal"], term) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }
}

// MARK: - Shared status helpers

private func statusKey(_ s: AgentStatus) -> String {
    switch s {
    case .running: return "running"
    case .processing: return "processing"
    case .waitingApproval, .waitingQuestion: return "waiting"
    case .idle: return "idle"
    }
}

private func statusLabel(_ s: AgentStatus) -> String {
    let l = L10n.shared
    switch s {
    case .running: return l["status_running"]
    case .processing: return l["status_processing"]
    case .waitingApproval, .waitingQuestion: return l["status_waiting"]
    case .idle: return l["status_idle"]
    }
}

private func statusColor(_ s: AgentStatus) -> Color {
    switch s {
    case .running, .processing: return IslandGlowPalette.running
    case .waitingApproval, .waitingQuestion: return IslandGlowPalette.attention
    case .idle: return .secondary
    }
}
