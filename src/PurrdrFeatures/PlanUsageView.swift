import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 方案用量畫面(#177、DESIGN.md「方案用量」)。
///
/// 上方兩列選「主機」「Agent」,下面以兩個圓環顯示 5 小時與每週用量週期(中央是剩餘或已用比例)。
/// 錯誤與同意狀態取代圓環。只在畫面出現、改選、下拉時查詢;不耗 token 與傳輸的來源才在畫面開著時自動重整。
public struct PlanUsageView: View {
    @Bindable var model: PlanUsageModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: PlanUsageModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Group {
                Section {
                    Picker("Host", selection: hostSelection) {
                        ForEach(model.hosts) { option in
                            HostMenuLabel(option).tag(option.id)
                        }
                    }
                    .accessibilityIdentifier("planUsage.host")
                } footer: {
                    costNote
                }
                // Agent 攤開成勾選列(#313);已用／剩餘是全域偏好,在設定 tab(#393)。
                Section {
                    Picker("Agent", selection: agentSelection) {
                        ForEach(model.agents, id: \.self) { agent in
                            Text(verbatim: agent.name).tag(agent)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("planUsage.agent")
                } header: {
                    Text("Agent")
                        .foregroundStyle(.secondaryText)
                }
                Section {
                    content
                } footer: {
                    footnote
                }
            }
            // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
            .listRowBackground(AppSurface.groupedRow)
        }
        .appGroupedList()
        .navigationTitle("Plan Usage")
        .refreshable { await model.refresh() }
        .toolbar { options }
        .alert(consentAlertTitle, isPresented: confirming) {
            Button("Change Settings") { Task { await model.confirm() } }
            Button("Cancel", role: .cancel) { model.cancelConsent() }
        } message: {
            Text(consentMessage)
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.enteredBackground()
            default: break
            }
        }
    }

    private var hostName: String {
        model.hosts.first { $0.id == model.host }?.name ?? ""
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            PlanUsageMessage(systemImage: nil, title: "Checking \(hostName)…", detail: nil)
        case .loaded:
            let groups = model.rowGroups
            if groups.isEmpty {
                noData
            } else {
                // 同一用量週期依模型群組有多份(Antigravity):每個群組一列圓環,標明群組(#448)。
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.group) { entry in
                        if let title = entry.group.title {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondaryText)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("planUsage.group.\(entry.group.accessibilityKey)")
                        }
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(entry.rows) { row in
                                PlanUsageRingView(row: row, display: model.display)
                                    .accessibilityIdentifier(row.accessibilityIdentifier)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        case .noData:
            noData
        case .noAgentEnabled:
            PlanUsageMessage(
                systemImage: "tray", title: "No Agents are turned on", detail: "Open the Hosts tab, then Agent, to turn one on.")
        case .needsConsent, .confirming:
            PlanUsageMessage(
                systemImage: "lock", title: model.agent == .antigravity ? "Show Antigravity plan usage on this host?" : "Show Claude plan usage on this host?",
                detail: model.agent == .antigravity
                    ? "Purrdr changes the Antigravity status line on \(hostName) so it saves plan usage. You can turn it off and restore the original anytime."
                    : "Purrdr changes the Claude Code status line on \(hostName) so it saves plan usage. You can turn it off and restore the original anytime."
            ) {
                Button("Check and Show") { Task { await model.requestConsent() } }
                    .filledProminentButtonStyle()
                    .accessibilityIdentifier("planUsage.consent")
            }
        case .checking:
            PlanUsageMessage(systemImage: nil, title: "Checking the host…", detail: nil)
        case .installing:
            PlanUsageMessage(systemImage: nil, title: model.agent == .antigravity ? "Changing the host’s Antigravity settings…" : "Changing the host’s Claude settings…", detail: nil)
        case .turningOff:
            PlanUsageMessage(systemImage: nil, title: model.agent == .antigravity ? "Restoring the host’s Antigravity settings…" : "Restoring the host’s Claude settings…", detail: nil)
        case .unsupportedConnection:
            PlanUsageMessage(
                systemImage: "nosign", title: "Plan usage isn’t available for this connection method",
                detail: "\(hostName) can’t show plan usage. Choose another host.")
        case .failed(let failure):
            PlanUsageMessage(
                systemImage: "exclamationmark.triangle", title: "Couldn’t check \(hostName)", detail: "\(failure.text) Pull down to try again."
            ) {
                // 要使用者在主機上執行的指令一律有拷貝鈕(#359)。
                if failure == .codexNotSignedIn {
                    InstructionView(instruction: AddHostGuideInstruction(text: String(localized: "Run this on the host:"), command: "codex login"))
                        .padding(.horizontal)
                }
            }
        }
        if let message = model.message {
            ErrorLabel(message, area: "PlanUsage")
                .font(.footnote)
                .accessibilityIdentifier("planUsage.message")
        }
    }

    private var noData: some View {
        PlanUsageMessage(
            systemImage: "hourglass", title: model.agent == .antigravity ? "Antigravity hasn’t reported plan usage yet" : "Claude Code hasn’t reported plan usage yet",
            detail: model.agent == .antigravity
                ? "Use Antigravity once on \(hostName), then pull down to refresh."
                : "Use Claude Code once on \(hostName), then pull down to refresh.")
    }

    /// 查詢方式(DESIGN.md:選單與圓環之間標出)。
    @ViewBuilder
    private var costNote: some View {
        if let cost = model.cost {
            Group {
                if cost.refreshesAutomatically {
                    Label("Uses no tokens or data · Refreshes automatically while open", systemImage: "arrow.clockwise")
                } else {
                    Label("Uses data, not tokens · Pull down to check again", systemImage: "hand.draw")
                }
            }
            .foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if case .loaded(let usage) = model.state, !model.rows.isEmpty {
            Group {
                switch (model.agent, PlanUsagePresentation.asOf(usage, now: .now)) {
                case (.claudeCode, let asOf?):
                    Text("As of \(asOf, format: .dateTime.hour().minute()), when Claude Code last reported on this host.")
                case (.claudeCode, nil):
                    Text("Claude Code reports these numbers while it runs on this host.")
                case (.codex, let asOf?):
                    Text("As of \(asOf, format: .dateTime.hour().minute()). Codex reports these numbers for the ChatGPT plan Codex is signed in with on this host.")
                case (.codex, nil):
                    Text("Codex reports these numbers for the ChatGPT plan Codex is signed in with on this host.")
                case (.antigravity, let asOf?):
                    Text("As of \(asOf, format: .dateTime.hour().minute()), when Antigravity last reported on this host.")
                case (.antigravity, nil):
                    Text("Antigravity reports these numbers while it runs on this host.")
                }
            }
            .foregroundStyle(.secondaryText)
        }
    }

    @ToolbarContentBuilder
    private var options: some ToolbarContent {
        // 「⋯」只放這頁的動作(#313):沒有可關閉的就不顯示。
        if model.canTurnOff {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if model.wrapperUpdateAvailable {
                        Button("Update Claude Usage Script", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await model.requestWrapperUpdate() }
                        }
                        .accessibilityIdentifier("planUsage.updateWrapper")
                    }
                    Button(turnOffTitle, systemImage: "arrow.uturn.backward", role: .destructive) {
                        Task { await model.turnOff() }
                    }
                } label: {
                    Label("Plan Usage Options", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("planUsage.menu")
            }
        }
    }

    private var consentAlertTitle: LocalizedStringKey {
        model.agent == .antigravity ? "Show Antigravity Plan Usage?" : "Show Claude Plan Usage?"
    }

    private var turnOffTitle: LocalizedStringKey {
        model.agent == .antigravity ? "Turn Off Antigravity Plan Usage" : "Turn Off Claude Plan Usage"
    }

    private var hostSelection: Binding<HostSelection> {
        Binding { model.host } set: { model.select(host: $0) }
    }

    private var agentSelection: Binding<PlanUsageAgent> {
        Binding { model.agent } set: { model.select(agent: $0) }
    }

    private var confirming: Binding<Bool> {
        Binding {
            if case .confirming = model.state { return true }
            return false
        } set: { _ in
            // alert 關閉時 SwiftUI 會先設 false 再執行按鈕;狀態交給按鈕處理，否則「確認」會先被當成取消。
        }
    }

    private var consentMessage: String {
        guard case .confirming(let user) = model.state else { return "" }
        if model.agent == .antigravity {
            return String(localized: "To show plan usage, Purrdr changes one Antigravity setting on this host (signed in as \(user)). Turning this off puts it back.")
        }
        return String(localized: "To show plan usage, Purrdr changes one Claude Code setting on this host (signed in as \(user)). Turning this off puts it back.")
    }
}

extension PlanUsageFailure {
    /// 畫面上的說明。
    var text: String {
        switch self {
        case .codexNotFound:
            String(localized: "This host can’t find Codex. Install Codex there first.")
        case .codexNotSignedIn:
            String(localized: "Codex isn’t signed in on this host. Sign in there with the command below.")
        case .codexUnreadableResponse:
            String(localized: "Purrdr couldn’t read Codex’s answer. Updating Codex on the host may help.")
        case .codexTimedOut:
            String(localized: "Codex didn’t answer in time.")
        case .codexRequestFailed(let message):
            String(localized: "Codex couldn’t get plan usage: \(message)")
        case .connection(let message):
            message
        }
    }
}

extension PlanUsage.Period.Kind {
    /// 用量週期的名稱(畫面與 VoiceOver 共用)。
    var name: LocalizedStringResource {
        switch self {
        case .fiveHour: "5 Hours"
        case .week: "Weekly"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .fiveHour: "planUsage.period.fiveHour"
        case .week: "planUsage.period.week"
        }
    }
}

extension PlanUsageAgent {
    /// 產品名稱，不翻譯。
    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }
}

/// 取代圓環的置中說明(查詢中、需要同意、錯誤)。`systemImage` 為 `nil` 時是載入中。
private struct PlanUsageMessage<Actions: View>: View {
    let systemImage: String?
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    @ViewBuilder var actions: Actions

    init(systemImage: String?, title: LocalizedStringKey, detail: LocalizedStringKey?, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        if let systemImage {
            // 空狀態與說明一律系統的 ContentUnavailableView(#626),不自己畫圖示加文字。
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let detail { Text(detail) }
            } actions: {
                actions
            }
        } else {
            // 局部動作進行中(查詢、安裝、還原):小轉圈加說明。
            VStack(spacing: 8) {
                ProgressView()
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

extension PlanUsageMessage where Actions == EmptyView {
    init(systemImage: String?, title: LocalizedStringKey, detail: LocalizedStringKey?) {
        self.init(systemImage: systemImage, title: title, detail: detail) { EmptyView() }
    }
}

/// 一個用量週期的圓環：中央是剩餘或已用比例，下方是用量週期名稱與重置時間;顏色依剩餘比例分三級。
struct PlanUsageRingView: View {
    let row: PlanUsageRow
    let display: PlanUsageModel.Display
    @ScaledMetric(relativeTo: .title2) private var diameter: CGFloat = 104
    @ScaledMetric(relativeTo: .title2) private var lineWidth: CGFloat = 11

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.fill.tertiary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: row.fraction)
                    .stroke(AccessibleColors.planUsage(row.level).color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(verbatim: "\(row.percent)%")
                        .font(.title2.bold().monospacedDigit())
                    Text(display == .remaining ? "left" : "used")
                        .font(.caption)
                        .foregroundStyle(.secondaryText)
                }
            }
            .frame(width: diameter, height: diameter)
            Text(row.period.name)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            if let resetsAt = row.resetsAt {
                Text("Resets \(resetsAt, format: Self.resetFormat(resetsAt))")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    /// VoiceOver:名稱、比例、重置時間。
    private var accessibilityText: String {
        let name = String(localized: row.period.name)
        let amount = display == .remaining ? String(localized: "\(row.percent)% left") : String(localized: "\(row.percent)% used")
        guard let resetsAt = row.resetsAt else { return "\(name), \(amount)" }
        return "\(name), \(amount), " + String(localized: "Resets \(resetsAt.formatted(Self.resetFormat(resetsAt)))")
    }

    /// 一天內只顯示時間，否則加上星期。時間依裝置地區與 12/24 小時制。
    static func resetFormat(_ date: Date, now: Date = Date()) -> Date.FormatStyle {
        date.timeIntervalSince(now) < PlanUsage.Period.day ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
    }
}

extension PlanUsage.Group {
    /// 詳細面板的群組標題;只有一個群組(`.general`)時沒有。
    var title: LocalizedStringResource? {
        switch self {
        case .general: nil
        case .gemini: "Gemini Models"
        case .thirdParty: "Third-Party Models"
        }
    }

    var accessibilityKey: String {
        switch self {
        case .general: "general"
        case .gemini: "gemini"
        case .thirdParty: "thirdParty"
        }
    }
}

extension PlanUsageRow {
    /// 圓環的識別碼:一般是 `planUsage.period.<週期>`,有模型群組的(Antigravity)多一段群組,兩組的同一週期才分得開。
    var accessibilityIdentifier: String {
        group == .general ? period.accessibilityIdentifier : "planUsage.period.\(group.accessibilityKey).\(period.accessibilityKey)"
    }
}
