import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 從卡片或背景 agents 列推入的畫面(行為規格 F10)。
public enum DelegationRoute: Hashable {
    case subagent(SubagentCard)
    case workflow(WorkflowCard)
    case workflowAgent(WorkflowCard, WorkflowAgent)
}

/// 卡片需要的對話層能力(由 `ConversationView` 注入;subagent 畫面裡的巢狀卡沿用同一個)。
struct DelegationContext {
    var workflowModel: @MainActor (WorkflowCard) -> WorkflowModel? = { _ in nil }
    var canOpen: @MainActor (SubagentCard) -> Bool = { _ in false }
}

extension EnvironmentValues {
    @Entry var delegationContext = DelegationContext()
}

// MARK: - 狀態圖示

/// 執行中轉圈、完成勾、失敗驚嘆(錯誤色)。狀態同時有 VoiceOver 文字，不只靠顏色與形狀。
struct DelegationStatusIcon: View {
    let status: DelegationStatus

    var body: some View {
        Group {
            switch status {
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(status.tone.style)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(status.tone.style)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(status.title)
    }
}

extension DelegationStatus {
    var title: Text {
        switch self {
        case .running: Text("Running")
        case .completed: Text("Done")
        case .failed: Text("Failed")
        }
    }
}

// MARK: - Subagent 卡

/// Subagent 卡(內容層，不用 Liquid Glass)。點本體展開結果(最多 24 行，可選取);箭頭開 subagent 畫面，
/// 沒有 session 資料夾或沒有呼叫 id 時停用。
struct SubagentCardView: View {
    let card: SubagentCard
    @Environment(\.delegationContext) private var context
    private let expansion = ExpansionState(partID: "subagent")
    private var expanded: Bool {
        get { expansion.binding.wrappedValue }
        nonmutating set { expansion.binding.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "cpu")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.leading)
                            if let subtitle = DelegationText.subtitle(of: card) {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondaryText)
                            }
                            let stats = DelegationText.stats(of: card)
                            if !stats.isEmpty {
                                Text(stats)
                                    .font(.footnote)
                                    .foregroundStyle(.secondaryText)
                            }
                        }
                        Spacer(minLength: 4)
                        DelegationStatusIcon(status: card.status)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(card.result == nil)
                .accessibilityHint(card.result == nil ? Text("") : Text(expanded ? "Hides the result" : "Shows the result"))
                .accessibilityIdentifier("conversation.subagent")

                DelegationRouteLink(route: .subagent(card)) {
                    Image(systemName: "chevron.forward")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!context.canOpen(card))
                .accessibilityLabel(Text("Open Subagent"))
                .accessibilityIdentifier("conversation.subagent.open")
            }
            if expanded, let result = card.result, !result.isEmpty {
                Text(result.split(separator: "\n", omittingEmptySubsequences: false).prefix(24).joined(separator: "\n"))
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.subagent.result")
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Workflow 卡

/// Workflow 卡：狀態、「2 of 3 agents done」、時長、tokens、摘要;展開後依 phase 列 agent;結果只在非執行中時顯示。
/// 執行中或展開時每 3 秒讀進度(與 workflow 畫面共用同一個 model)。
struct WorkflowCardView: View {
    let card: WorkflowCard
    @Environment(\.delegationContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    private let expansion = ExpansionState(partID: "workflow")
    private var expanded: Bool {
        get { expansion.binding.wrappedValue }
        nonmutating set { expansion.binding.wrappedValue = newValue }
    }

    var body: some View {
        let model = context.workflowModel(card)
        let run = model?.run
        let status = model?.isTracking == false && run?.isRunning == false && card.status == .running ? .completed : card.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run?.name ?? card.name)
                                .font(.subheadline.weight(.semibold))
                            if let detail = card.detail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondaryText)
                                    .multilineTextAlignment(.leading)
                            }
                            let line = [run.flatMap(DelegationText.progress(of:)), DelegationText.stats(of: card, run: run)]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                            if !line.isEmpty {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(.secondaryText)
                            }
                            if let reason = model?.unavailableReason {
                                Text(reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondaryText)
                            } else if model?.stoppedTracking == true {
                                Text("No longer tracking · Reload to check again")
                                    .font(.footnote)
                                    .foregroundStyle(.secondaryText)
                            }
                        }
                        Spacer(minLength: 4)
                        DelegationStatusIcon(status: status)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation.workflow")

                DelegationRouteLink(route: .workflow(card)) {
                    Image(systemName: "chevron.forward")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(model == nil)
                .accessibilityLabel(Text("Open Workflow"))
                .accessibilityIdentifier("conversation.workflow.open")
            }
            if expanded {
                if let summary = run?.summary ?? (status == .running ? nil : card.result) {
                    Text(summary)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                ForEach(run?.phases ?? []) { phase in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(phase.title)
                            .font(.footnote.weight(.semibold))
                        ForEach(phase.agents) { agent in
                            Label {
                                Text(agent.label).font(.footnote)
                            } icon: {
                                DelegationStatusIcon(status: agent.state)
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: TrackKey(running: card.status == .running, expanded: expanded, active: scenePhase == .active)) {
            guard scenePhase == .active, card.status == .running || expanded else { return }
            await model?.track()
        }
    }

    private struct TrackKey: Hashable {
        var running: Bool
        var expanded: Bool
        var active: Bool
    }
}

// MARK: - 畫面

/// 由 route 建立畫面;model 只在第一次建立(navigationDestination 的內容可能被重建)。
struct DelegationDestination: View {
    let route: DelegationRoute
    let conversation: ConversationModel

    var body: some View {
        // 推入的畫面不繼承來源畫面的 environment:巢狀卡要的能力在這裡再給一次。
        destination
            .environment(\.delegationContext, DelegationContext(
                workflowModel: { [conversation] in conversation.workflowModel(for: $0) },
                canOpen: { [conversation] in conversation.canOpen($0) }
            ))
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .subagent(let card):
            SubagentScreenHolder(model: conversation.subagentModel(for: card))
        case .workflow(let card):
            if let model = conversation.workflowModel(for: card) {
                WorkflowScreen(model: model)
            } else {
                unavailable
            }
        case .workflowAgent(let card, let agent):
            SubagentScreenHolder(model: conversation.workflowAgentModel(card: card, agent: agent))
        }
    }

    private var unavailable: some View {
        ContentUnavailableView("Not on This Host", systemImage: "questionmark.folder")
    }
}

private struct SubagentScreenHolder: View {
    @State private var model: SubagentModel?

    init(model: @autoclosure () -> SubagentModel?) {
        _model = State(wrappedValue: model())
    }

    var body: some View {
        if let model {
            SubagentScreen(model: model)
        } else {
            ContentUnavailableView("Not on This Host", systemImage: "questionmark.folder")
        }
    }
}

/// Subagent 畫面(唯讀，沒有輸入框):標題、副標(類型 · 模型)、狀態;內容如主對話(含巢狀卡、永遠顯示 sidechain)。
struct SubagentScreen: View {
    let model: SubagentModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .navigationTitle(model.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    DelegationStatusIcon(status: model.status)
                    if let subtitle = model.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("subagent.header")
            }
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.run()
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            switch model.phase {
            case .starting:
                ContentUnavailableView {
                    Label("Starting", systemImage: "hourglass")
                } description: {
                    Text("The subagent’s messages appear here once it starts.")
                }
            case .notOnHost:
                ContentUnavailableView {
                    Label("Not on This Host", systemImage: "questionmark.folder")
                } description: {
                    Text("This subagent’s messages aren’t on this host.")
                }
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Host Service Update Needed", systemImage: "arrow.down.circle")
                } description: {
                    Text(reason)
                }
            case .ready:
                ContentUnavailableView("No Messages Yet", systemImage: "bubble.left.and.bubble.right")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.items) { item in
                        ConversationItemView(item: item)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .accessibilityIdentifier("subagent.messages")
        }
    }
}

/// Workflow 畫面：摘要、各 phase(標題、細節、agent 列含 tokens、工具數、目前在做什麼／結果預覽／錯誤)、記錄框;
/// 每個 agent 列可開其對話紀錄。
struct WorkflowScreen: View {
    let model: WorkflowModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.run?.name ?? model.card.name)
                            .font(.headline)
                        Spacer()
                        DelegationStatusIcon(status: model.run.map { $0.isRunning ? DelegationStatus.running : .completed } ?? model.card.status)
                    }
                    if let detail = model.card.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondaryText)
                    }
                    let line = [model.run.flatMap(DelegationText.progress(of:)), DelegationText.stats(of: model.card, run: model.run)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !line.isEmpty {
                        Text(line).font(.footnote).foregroundStyle(.secondaryText)
                    }
                    if model.stoppedTracking {
                        Text("No longer tracking · Reload to check again").font(.footnote).foregroundStyle(.secondaryText)
                    }
                    if let summary = model.run?.summary {
                        Text(summary).font(.body).textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workflow.summary")
            }
            ForEach(model.run?.phases ?? []) { phase in
                Section {
                    if let detail = phase.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondaryText)
                    }
                    ForEach(phase.agents) { agent in
                        if agent.agentID != nil {
                            NavigationLink(value: DelegationRoute.workflowAgent(model.card, agent)) {
                                WorkflowAgentRow(agent: agent)
                            }
                            .accessibilityIdentifier("workflow.agent.\(agent.id)")
                        } else {
                            WorkflowAgentRow(agent: agent)
                        }
                    }
                } header: {
                    Text(phase.title)
                        .foregroundStyle(.secondaryText)
                }
            }
            if let logs = model.run?.logs, !logs.isEmpty {
                Section {
                    Text(logs.joined(separator: "\n"))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Log")
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .appGroupedList()
        .navigationTitle(model.run?.name ?? model.card.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if model.run == nil, let reason = model.unavailableReason {
                ContentUnavailableView {
                    Label("Host Service Update Needed", systemImage: "arrow.down.circle")
                } description: {
                    Text(reason)
                }
            } else if model.run == nil {
                ContentUnavailableView {
                    Label("Starting", systemImage: "hourglass")
                } description: {
                    Text("The workflow’s phases appear here once it starts.")
                }
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await model.track()
        }
    }
}

struct WorkflowAgentRow: View {
    let agent: WorkflowAgent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DelegationStatusIcon(status: agent.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label).font(.body)
                let stats = DelegationText.workflowAgentStats(agent)
                if !stats.isEmpty {
                    Text(stats).font(.footnote).foregroundStyle(.secondaryText)
                }
                if let error = agent.error {
                    ErrorLabel(error).font(.footnote)
                } else if agent.state == .running, let activity = agent.activity {
                    Text(activity).font(.footnote.monospaced()).foregroundStyle(.secondaryText).lineLimit(2)
                } else if let preview = agent.resultPreview {
                    Text(preview).font(.footnote).foregroundStyle(.secondaryText).lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 背景 agents 列

/// 背景 agents 的一列(狀態、種類、任務、經過時間 · tokens)。清單在狀態 sheet(#349),工作中膠囊只帶數量。
struct AgentsBarRow: View {
    private func detail(at date: Date) -> some View {
        let since = readAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return Text([DelegationText.elapsed(of: row, secondsSinceRead: since), row.tokens.map(DelegationText.tokens)].compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondaryText)
            .monospacedDigit()
    }

    let row: AgentsPane.Row
    /// 讀到這一列的時間;經過時間從它起算，每秒更新(只在前景，只重畫這一行,#498)。
    let readAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DelegationStatusIcon(status: row.state)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(DelegationText.kind(row.kind)) · \(row.task)")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                if scenePhase == .active {
                    TimelineView(.periodic(from: .now, by: 1)) { context in detail(at: context.date) }
                } else {
                    detail(at: .now)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
