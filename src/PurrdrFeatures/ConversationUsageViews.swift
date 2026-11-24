import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 頂列用量環按鈕(#513,原型 Main):和「⋯」放在同一個 `ToolbarItemGroup`,系統把它們合成一顆玻璃膠囊 [用量環｜⋯]。
/// 觸控目標 ≥ 44pt;點了開用量 sheet。
struct UsageRingButton: View {
    let summary: UsageSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            UsageRingView(summary: summary)
                .frame(minWidth: TopBarMetrics.circleDiameter, minHeight: TopBarMetrics.controlHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(verbatim: summary.accessibilityText))
        .accessibilityHint(Text("Shows usage details."))
        .accessibilityIdentifier("conversation.usage")
    }
}

/// 用量環:一個小圓環,填滿比例是顯示的數字,顏色依等級(一般、70% 起橙、85% 起紅);數字另在 VoiceOver 與用量 sheet。
struct UsageRingView: View {
    let summary: UsageSummary
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: summary.fraction)
                .stroke(summary.level.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 用量 sheet(#513,原型 Usage):左上 X、右上重新整理;內容是可單獨嵌入的 `UsageContentView`(#517 的 iPad 右側 inspector 也放它)。
struct ConversationUsageSheet: View {
    let model: ConversationModel
    /// 這台主機的方案用量(`nil`:這種 Agent 沒有方案用量來源)。
    let section: UsageSectionModel?
    let display: PlanUsageModel.Display
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            UsageContentView(model: model, section: section, display: display)
                .navigationTitle("Usage")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    SheetCloseToolbar(identifier: "usage.sheet.close")
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                            .disabled(isRefreshing || section == nil)
                            .accessibilityIdentifier("usage.sheet.refresh")
                    }
                }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("usage.sheet")
    }

    private func refresh() {
        guard let section else { return }
        isRefreshing = true
        Task {
            await section.refresh()
            isRefreshing = false
        }
    }
}

/// 用量內容(#513):「這個聊天」的 Context 卡片、「方案用量 · 主機名」的目前工作階段與每週卡片、更新時間。
/// 不含 NavigationStack、關閉與重新整理(由容器的 toolbar 放),sheet 與 #517 的 inspector 共用。
struct UsageContentView: View {
    let model: ConversationModel
    let section: UsageSectionModel?
    let display: PlanUsageModel.Display

    private var hostName: String { section?.hostName ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("This Chat")
                contextCard
                (section == nil ? sectionTitle("Plan Usage") : sectionTitle("Plan Usage · \(hostName)")).padding(.top, 6)
                planContent
                if let captured = section?.lastCapturedAt {
                    Text("Updated \(captured, format: .relative(presentation: .named))")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .accessibilityIdentifier("usage.sheet.updated")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .appPageContentWidth()
        }
        .background(AppSurface.groupedPage)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondaryText)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppSurface.groupedRow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityIdentifier(identifier)
    }
}

/// 用量 sheet 的一張卡片:標題、已用或剩餘百分比、8pt 進度條、一行說明(已用／總 token 或重設時間)。
private struct UsageCard: View {
    let title: Text
    let value: Text
    let fraction: Double
    let tint: AnyShapeStyle
    let detail: Text?
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme

    private var track: Color {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(colorScheme == .dark ? 0.28 : 0.16)
    }

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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSurface.groupedRow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
