import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 頂列用量環按鈕(#513、#617):和「⋯」放在同一個 `ToolbarItemGroup`,系統把它們合成一顆玻璃膠囊 [用量環｜⋯]。
/// 不自加寬度(交給系統排版);永遠顯示:一進聊天是系統載入動畫(#644),讀到資料換成百分比環,沒有資料是空環。
/// 點了開面板(iPad popover、iPhone sheet),從按鈕展開,載入中也可以點。
struct UsageRingButton: View {
    let state: UsageRingState
    /// regular 寬度才用的 popover 開關(compact 的 sheet 掛在聊天畫面上)。
    let showsPopover: Binding<Bool>
    let tap: () -> Void
    let model: ConversationModel
    let usageSection: UsageSectionModel?
    let display: PlanUsageModel.Display

    var body: some View {
        Button(action: tap) {
            UsageRingView(state: state)
        }
        .accessibilityLabel(Text(verbatim: state.summary?.accessibilityText ?? String(localized: "Usage")))
        .accessibilityValue(Text(state == .loading ? "Loading" : ""))
        .accessibilityHint(Text("Shows usage and details."))
        .accessibilityIdentifier("conversation.usage")
        .conversationPanelPopover(isPresented: showsPopover, model: model, usageSection: usageSection, display: display)
    }
}

/// 用量環:一個小圓環,填滿比例是顯示的數字,顏色依等級(一般、70% 起橙、85% 起紅);數字另在 VoiceOver 與面板。
/// 空環只畫軌道;載入中是系統 `ProgressView`(環形,不自畫動畫,「減少動態效果」由系統處理),
/// 三種狀態都在同一個固定大小的框裡,切換不造成頂列版面位移。
struct UsageRingView: View {
    let state: UsageRingState
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            if state == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("conversation.usage.loading")
            } else {
                Circle().stroke(.quaternary, lineWidth: lineWidth)
                if let summary = state.summary {
                    Circle()
                        .trim(from: 0, to: summary.fraction)
                        .stroke(summary.level.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 用量內容(#513):「這個聊天」的 Context、「方案用量 · 主機名」的目前工作階段與每週、更新時間。
/// 輸出系統 `Section`(標題、列、註腳都是系統的,#627),放進面板的 `List`;進度條自畫(系統不能指定軌道色)。
/// 不含 NavigationStack、關閉與重新整理(由面板的 toolbar 放),面板(`ConversationPanelView`)用。
struct UsageContentView: View {
    let model: ConversationModel
    let section: UsageSectionModel?
    let display: PlanUsageModel.Display

    private var hostName: String { section?.hostName ?? "" }

    var body: some View {
        Section("This Chat") {
            contextCard
        }
        Section {
            planContent
        } header: {
            if section == nil { Text("Plan Usage") } else { Text("Plan Usage · \(hostName)") }
        } footer: {
            if let captured = section?.lastCapturedAt {
                Text("Updated \(captured, format: .relative(presentation: .named))")
                    .accessibilityIdentifier("usage.sheet.updated")
            }
        }
    }

    // MARK: Context

    @ViewBuilder
    private var contextCard: some View {
        let progress = model.displayProgress
        if let used = progress.contextPercent {
            let shown = display == .used ? used : 100 - used
            UsageCard(
                title: Text("Context"), value: display == .used ? Text("\(shown)% used") : Text("\(shown)% left"),
                fraction: Double(shown) / 100, tint: progress.contextLevel.tint, detail: contextDetail,
                identifier: "usage.sheet.context")
        } else {
            note(Text("This chat hasn’t reported context yet."), identifier: "usage.sheet.context.empty")
        }
    }

    private var contextDetail: Text? {
        guard let counts = model.contextTokenCounts else { return nil }
        let style = IntegerFormatStyle<Int>.number.notation(.compactName)
        return Text("\(counts.used.formatted(style)) of \(counts.limit.formatted(style)) tokens")
    }

    // MARK: 方案用量

    @ViewBuilder
    private var planContent: some View {
        if let section {
            if section.isUnsupported {
                note(
                    Text("Plan usage needs host service \(HostServiceFeature.planUsage.minimumVersion.description) or later. Update the host service on the host."),
                    identifier: "usage.sheet.unsupported")
            } else {
                ForEach(section.entries) { entry in
                    entryContent(entry, section: section)
                }
            }
        } else {
            note(Text("Plan usage isn’t available for this agent."), identifier: "usage.sheet.noSource")
        }
    }

    @ViewBuilder
    private func entryContent(_ entry: UsageSectionModel.Entry, section: UsageSectionModel) -> some View {
        switch entry.state {
        case .rows:
            ForEach(entry.rows) { row in
                let source: UsageSummary.Source = row.period == .week ? .weekly : .currentSession
                UsageCard(
                    title: Text(verbatim: source.name),
                    value: display == .used ? Text("\(row.percent)% used") : Text("\(row.percent)% left"),
                    fraction: row.fraction, tint: AnyShapeStyle(AccessibleColors.planUsage(row.level).color),
                    detail: row.resetsAt.map { Text("Resets \($0, format: PlanUsageRingView.resetFormat($0))") },
                    identifier: "usage.sheet.\(row.period.accessibilityKey)")
            }
        case .loading:
            note(Text("Loading plan usage…"), identifier: "usage.sheet.loading")
        case .noData:
            note(Text("\(entry.agent.shortName) hasn’t reported plan usage yet."), identifier: "usage.sheet.noData")
        case .needsEnable:
            note(
                Text("To see \(entry.agent.shortName)’s plan usage, turn on usage display for \(hostName)."), identifier: "usage.sheet.needsEnable")
        case .failed(let failure):
            note(Text(verbatim: failure.text), identifier: "usage.sheet.failed")
        }
    }

    private func note(_ text: Text, identifier: String) -> some View {
        text
            .font(.subheadline)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

/// 用量面板的一列:標題、已用或剩餘百分比、8pt 進度條、一行說明(已用／總 token 或重設時間)。
private struct UsageCard: View {
    let title: Text
    let value: Text
    let fraction: Double
    let tint: AnyShapeStyle
    let detail: Text?
    let identifier: String

    private var track: Color { AccessibleColors.usageTrack }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 大字級放不下並排時改上下排,標題不被擠成斷字。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title.font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    value.font(.subheadline).foregroundStyle(.secondaryText).monospacedDigit().lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.headline)
                    value.font(.subheadline).foregroundStyle(.secondaryText).monospacedDigit()
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(tint).frame(width: max(fraction > 0 ? 8 : 0, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            if let detail {
                detail.font(.footnote).foregroundStyle(.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
