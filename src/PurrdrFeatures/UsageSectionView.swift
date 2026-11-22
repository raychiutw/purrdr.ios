import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 用量區的環境(#389):面板與主機 tab 取得用量區 model 與「啟用用量顯示」導向的同意流程。
/// 由 `TopNavigationView` 依 `HostsModel` 設定;沒設定(預覽)時不顯示用量區。
struct UsageSectionContext {
    var display: UsageDisplaySetting
    var section: @MainActor (HostSelection, [PlanUsageAgent]) -> UsageSectionModel
    var planUsage: @MainActor (HostSelection, PlanUsageAgent) -> PlanUsageModel
}

extension EnvironmentValues {
    @Entry var usageSections: UsageSectionContext?
    /// 對話所在的主機(面板的用量區用)。
    @Entry var usageHost: HostSelection?
}

extension UsageSectionContext {
    init(hosts: HostsModel) {
        self.init(
            display: hosts.usageDisplay,
            section: { hosts.usageSection(host: $0, agents: $1) },
            planUsage: { hosts.planUsage(host: $0, agent: $1) })
    }
}

extension PlanUsageAgent {
    /// 用量條上的短名稱(Claude · 5 小時)。
    var shortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }

    /// 聊天 Agent 種類(herdr 回報的 `kind`)對應的用量來源;沒有的種類不顯示用量區。
    init?(agentKind: String?) {
        switch agentKind.map(AgentID.init(herdrName:)) {
        case .claude: self = .claudeCode
        case .codex: self = .codex
        default: return nil
        }
    }
}

/// 用量區(#389,原型 Host／PanelStates):每個用量週期一條進度條——「Claude · 5 小時」「38% 已用 · 14:00 重設」。
/// 面板放單一 Agent、標題寫明範圍(「用量 · Claude · 主機名」);主機 tab 放 Claude 與 Codex。
/// 尚未啟用、主機服務太舊、沒有資料與失敗都是區塊內的說明,區塊不無聲消失。
struct UsageSectionView: View {
    let model: UsageSectionModel
    let host: HostSelection
    /// 面板:標題帶 Agent 與主機名;主機 tab:標題只有「用量」。
    let scopedTitle: Bool
    @Environment(\.usageSections) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            if model.isUnsupported {
                Text("Plan usage needs host service \(HostServiceFeature.planUsage.minimumVersion.description) or later. Update the host service on the host.")
                    .foregroundStyle(.secondaryText)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("usage.unsupported")
            } else {
                ForEach(model.entries) { entry in
                    entryContent(entry)
                }
            }
        } header: {
            // 查詢的生命週期掛在標題上:區塊在畫面上才查,離開或進背景就停(Section 本身沒有單一的出現與消失)。
            header
                .foregroundStyle(.secondaryText)
                .task(id: scenePhase == .active) {
                    if scenePhase == .active { model.appeared() } else { model.disappeared() }
                }
                .onDisappear { model.disappeared() }
        }
    }

    private var header: Text {
        // 主機離線:保留最後讀到的資料,標題寫明是最後的資料與時間(#392)。
        if model.isShowingLastKnownData, let captured = model.lastCapturedAt {
            return Text("Plan Usage (Last Data · \(captured, format: .dateTime.hour().minute()))")
        }
        guard scopedTitle else { return Text("Plan Usage") }
        if !model.isUnsupported, let agent = model.entries.first?.agent, model.entries.count == 1 {
            return Text("Plan Usage · \(agent.shortName) · \(model.hostName)")
        }
        return Text("Plan Usage · \(model.hostName)")
    }

    @ViewBuilder
    private func entryContent(_ entry: UsageSectionModel.Entry) -> some View {
        switch entry.state {
        case .rows:
            ForEach(entry.rows) { row in
                UsageBarRow(agent: entry.agent, row: row, display: model.displaySetting.display, staleMinutes: entry.staleMinutes)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking \(entry.agent.shortName)…")
                    .foregroundStyle(.secondaryText)
            }
            .frame(minHeight: 44, alignment: .leading)
        case .noData:
            Text("\(entry.agent.shortName) hasn’t reported plan usage yet.")
                .foregroundStyle(.secondaryText)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("usage.noData.\(entry.agent.rawValue)")
        case .needsEnable:
            VStack(alignment: .leading, spacing: 8) {
                Text("To see \(entry.agent.shortName)’s plan usage, turn on usage display for \(model.hostName).")
                    .foregroundStyle(.secondaryText)
                if let context {
                    NavigationLink {
                        PlanUsageScreen(model: context.planUsage(host, entry.agent))
                    } label: {
                        Text("Enable Usage Display")
                            .fontWeight(.semibold)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("usage.enable.\(entry.agent.rawValue)")
                }
            }
            .padding(.vertical, 4)
        case .failed(let failure):
            Label(failure.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondaryText)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("usage.failed.\(entry.agent.rawValue)")
        }
    }
}

/// 持有用量區 model(重畫時不重建)。
struct UsageSectionContainer: View {
    let host: HostSelection
    let scopedTitle: Bool
    @State private var model: UsageSectionModel

    init(host: HostSelection, agents: [PlanUsageAgent], context: UsageSectionContext, scopedTitle: Bool) {
        self.host = host
        self.scopedTitle = scopedTitle
        _model = State(wrappedValue: context.section(host, agents))
    }

    var body: some View {
        UsageSectionView(model: model, host: host, scopedTitle: scopedTitle)
    }
}

/// 進畫面才建立並持有方案用量頁的 model(同意流程所在的既有畫面)。
struct PlanUsageScreen: View {
    @State private var model: PlanUsageModel

    init(model: @autoclosure () -> PlanUsageModel) {
        _model = State(wrappedValue: model())
    }

    var body: some View {
        PlanUsageView(model: model)
    }
}

/// 一個用量週期:上面是「Claude · 5 小時」與「38% 已用 · 14:00 重設」,下面是進度條。
/// 到門檻(已用 70% 起)在數字前加三角形;資料過舊時尾端改標「N 分鐘前」。
struct UsageBarRow: View {
    let agent: PlanUsageAgent
    let row: PlanUsageRow
    let display: PlanUsageModel.Display
    let staleMinutes: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(agent.shortName) · \(String(localized: row.period.name))")
                    .font(.subheadline)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    if row.showsWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AccessibleColors.planUsage(row.level).color)
                            .accessibilityHidden(true)
                    }
                    detail
                }
                .font(.subheadline)
            }
            UsageBar(fraction: row.fraction, level: row.level)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityIdentifier("usage.row.\(agent.rawValue).\(row.period.accessibilityKey)")
    }

    private var amount: Text {
        display == .used ? Text("\(row.percent)% used") : Text("\(row.percent)% left")
    }

    @ViewBuilder
    private var detail: some View {
        amount.fontWeight(.semibold).monospacedDigit()
        if let staleMinutes {
            Text("· \(staleMinutes) min ago").foregroundStyle(.secondaryText)
        } else if let resetsAt = row.resetsAt {
            Text("· Resets \(resetsAt, format: PlanUsageRingView.resetFormat(resetsAt))").foregroundStyle(.secondaryText)
        }
    }

    /// VoiceOver:「Claude · 5 小時, 38% 已用, 14:00 重設」;偏高時先說明,過舊時加上資料時間。
    private var accessibilityText: String {
        var parts = ["\(agent.shortName) · \(String(localized: row.period.name))"]
        parts.append(display == .used ? String(localized: "\(row.percent)% used") : String(localized: "\(row.percent)% left"))
        if row.showsWarning {
            parts.append(String(localized: "Running high"))
        }
        if let resetsAt = row.resetsAt {
            parts.append(String(localized: "Resets \(resetsAt.formatted(PlanUsageRingView.resetFormat(resetsAt)))"))
        }
        if let staleMinutes {
            parts.append(String(localized: "\(staleMinutes) min ago"))
        }
        return parts.joined(separator: ", ")
    }
}

/// 進度條:軌道加上依級距上色的填色(顏色只是圖形,數字與三角形另有傳達)。
struct UsageBar: View {
    let fraction: Double
    let level: PlanUsageLevel
    @Environment(\.colorScheme) private var colorScheme

    /// 軌道:`rgba(120,120,128)`,淺色 .16、深色 .28(DESIGN.md「低飽和用量色」)。
    private var track: Color {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(colorScheme == .dark ? 0.28 : 0.16)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(AccessibleColors.planUsage(level).color)
                    .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

extension PlanUsage.Period.Kind {
    var accessibilityKey: String {
        switch self {
        case .fiveHour: "fiveHour"
        case .week: "week"
        }
    }
}

/// 面板的 context 一列(原型 PanelStates):圓環加「Context 18% 已用」,已用或剩餘照全域設定。
struct ContextUsageRow: View {
    let percent: Int
    let level: AgentProgress.ContextLevel
    let display: PlanUsageModel.Display

    private var shown: Int { display == .used ? percent : 100 - percent }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.fill.tertiary, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                    .stroke(level.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            if display == .used {
                Text("Context \(shown)% used")
            } else {
                Text("Context \(shown)% left")
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display == .used ? Text("Context \(shown)% used") : Text("Context \(shown)% left"))
        .accessibilityIdentifier("progress.context")
    }
}
