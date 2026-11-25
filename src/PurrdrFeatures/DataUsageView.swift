import Accessibility
import Charts
import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 流量 tab 的入口:進頁面時才建立 model。
struct DataUsageScreen: View {
    @State private var model: DataUsageModel
    let account: AnyView

    init(make: () -> DataUsageModel, account: AnyView) {
        _model = State(wrappedValue: make())
        self.account = account
    }

    var body: some View {
        DataUsageView(model: model, account: account)
    }
}

/// 流量頁(#354、spec #337、#500、DESIGN.md「數據用量」)。
///
/// 共用頂列:大標題「流量」,右側單顆電腦圖示圓鈕(篩選主機,預設所有主機,篩選時右上角有小圓點)與頭像,沒有「＋」;
/// 往下滑大標題收成置中小標題。由上到下:兩個玻璃摘要方塊、期間與分類膠囊、30 天長條圖、各主機的用量、重設統計與說明。
public struct DataUsageView: View {
    @Bindable var model: DataUsageModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var optionsSheet: OptionsSheet?
    @State private var detailHostID: String?
    @State private var confirmsReset = false
    @State private var selectedDate: Date?
    /// 流量 tab 最右上角的帳號鈕(#390)。
    private let account: AnyView

    init(model: DataUsageModel, account: AnyView) {
        self.model = model
        self.account = account
    }

    enum OptionsSheet: String, Identifiable {
        case period, category
        var id: String { rawValue }
    }

    public var body: some View {
        ScrollView {
            // 邊距與其他頁一致(16pt,iPad 內容寬度上限由共用頁面給);上方起點由共用頂列給。
            VStack(alignment: .leading, spacing: 16) {
                summaryTiles
                chips
                chartCard
                hostsSection
                resetButton
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("dataUsage.page")
        .topBarPage(topBarContent)
        .sheet(item: $optionsSheet) { sheet in
            DataUsageOptionsSheet(model: model, sheet: sheet)
        }
        .sheet(item: Binding(get: { detailHostID.map(HostDetailID.init) }, set: { detailHostID = $0?.id })) { item in
            DataUsageHostSheet(model: model, hostID: item.id)
        }
        .confirmationDialog("Reset Statistics?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset Statistics", role: .destructive) { model.reset() }
                .accessibilityIdentifier("dataUsage.resetConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears all data usage recorded on this device.")
        }
        // 只在前景每 2 秒重讀(#498):進背景不再讓整頁失效;回前景先重讀一次再繼續。
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            model.refresh()
            await model.run()
        }
    }

    private var topBarContent: TopBarContent {
        TopBarContent(
            tab: .traffic, title: "Traffic",
            hostScope: TopBarHostScope(filteredHostName: model.hosts.first { $0.id == model.host }?.name),
            hostMenu: AnyView(DataUsageHostMenu(model: model)),
            hostIdentifier: "dataUsage.host",
            plus: nil, account: account)
    }

    // MARK: - 摘要

    private var summaryTiles: some View {
        HStack(spacing: 12) {
            SummaryTile(title: "This Launch", summary: model.sinceLaunch, identifier: "dataUsage.sinceLaunch")
            SummaryTile(title: "Today", summary: model.today, identifier: "dataUsage.today")
        }
        // 兩張卡一樣高(大字級下文字折行數不同時,以較高的那張為準)。
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 膠囊

    private var chips: some View {
        // 膠囊文字不折行;大字級一行放不下時改成直向排列。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chipButtons; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { chipButtons }
        }
    }

    @ViewBuilder
    private var chipButtons: some View {
        ChipButton(title: model.period.title, hint: "Period", identifier: "dataUsage.period") { optionsSheet = .period }
        ChipButton(title: model.category.title, hint: "Category", identifier: "dataUsage.category") { optionsSheet = .category }
    }

    // MARK: - 長條圖

    private var chartCard: some View {
        let bars = model.bars
        return VStack(alignment: .leading, spacing: 12) {
            legend(for: bars)
            DataUsageChart(bars: bars, selectedDay: model.selectedBar?.day) { day in model.selectBar(day: day) }
                .frame(height: 200)
                .accessibilityIdentifier("dataUsage.chart")
            selectionDetail
        }
        .padding(14)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func legend(for bars: [DataUsageBar]) -> some View {
        let kinds = Set(bars.flatMap { $0.segments.map(\.kind) })
        let shown = model.category.legendKinds.filter { $0 != .other || kinds.contains($0) }
        return HStack(spacing: 14) {
            ForEach(shown, id: \.self) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(kind.color).frame(width: 10, height: 10).accessibilityHidden(true)
                    Text(kind.title).font(.caption).foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("dataUsage.legend")
    }

    @ViewBuilder
    private var selectionDetail: some View {
        if let bar = model.selectedBar {
            VStack(alignment: .leading, spacing: 2) {
                Text(bar.date, format: .dateTime.month().day().weekday())
                    .font(.subheadline.weight(.semibold))
                Text(DataUsageFormat.bytes(bar.total)).font(.subheadline)
                ForEach(bar.segments, id: \.kind) { segment in
                    if model.category != .total {
                        Text(verbatim: "\(segment.kind.title) \(DataUsageFormat.bytes(segment.bytes))")
                            .font(.caption).foregroundStyle(.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dataUsage.selection")
        } else {
            Text("Tap a bar to see that day.")
                .font(.caption).foregroundStyle(.secondaryText)
        }
    }

    // MARK: - 主機

    @ViewBuilder
    private var hostsSection: some View {
        let rows = model.hostRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.period.hostsHeader)
                    .font(.footnote).foregroundStyle(.secondaryText).padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().padding(.leading, 56) }
                        Button { detailHostID = row.id } label: { HostUsageRow(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("dataUsage.host.\(row.id)")
                    }
                }
                .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    // MARK: - 重設與說明

    private var resetButton: some View {
        Button(role: .destructive) { confirmsReset = true } label: {
            Text("Reset Statistics").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.destructiveText)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("dataUsage.reset")
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Counts only the data Purrdr sends to and receives from your hosts.")
            if let since = model.countingSince {
                Text("Stored on this device only, counting since \(since.formatted(date: .abbreviated, time: .omitted)).")
            } else {
                Text("Stored on this device only. Nothing is counted yet.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("dataUsage.footnote")
    }
}

private struct HostDetailID: Identifiable {
    var id: String
}

// MARK: - 元件

/// 電腦圖示點開的主機選單內容:所有主機或某一台(主機選擇維持選單,DESIGN.md「選擇控制」例外)。
private struct DataUsageHostMenu: View {
    @Bindable var model: DataUsageModel

    var body: some View {
        Picker(selection: selection) {
            Text("All Hosts").tag(HostSelection?.none)
            ForEach(model.hosts) { option in
                HostMenuLabel(option).tag(HostSelection?.some(option.id))
            }
        } label: {
            Text("Host")
        }
        .pickerStyle(.inline)
    }

    private var selection: Binding<HostSelection?> {
        Binding { model.host } set: { model.selectHost($0) }
    }
}

/// 摘要方塊(玻璃):總量與一行行動網路。
private struct SummaryTile: View {
    let title: LocalizedStringKey
    let summary: DataUsageSummary
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondaryText)
            Text(DataUsageFormat.bytes(summary.total))
                .font(.title.weight(.bold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text("Cellular \(DataUsageFormat.bytes(summary.cellular))")
                .font(.caption).foregroundStyle(.secondaryText).monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// 期間與分類的選單膠囊:顯示目前的值加 ▾,點了開勾選列 sheet。
private struct ChipButton: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondaryText).accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Double-tap to change."))
        .accessibilityIdentifier(identifier)
    }
}

private struct HostUsageRow: View {
    let row: DataUsageHostRow

    var body: some View {
        HStack(spacing: 12) {
            HostIconBadge(row.icon, diameter: 32)
            VStack(alignment: .leading, spacing: 1) {
                if row.isDeleted {
                    Text("Deleted Host")
                } else {
                    Text(verbatim: row.name)
                }
                if row.cellular > 0 {
                    Text("Cellular \(DataUsageFormat.bytes(row.cellular))")
                        .font(.caption).foregroundStyle(.secondaryText)
                }
            }
            Spacer(minLength: 8)
            Text(DataUsageFormat.bytes(row.bytes.total)).foregroundStyle(.secondaryText).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// 期間與分類的勾選列 sheet(DESIGN.md「選擇控制」「選單膠囊」)。
private struct DataUsageOptionsSheet: View {
    @Bindable var model: DataUsageModel
    let sheet: DataUsageView.OptionsSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch sheet {
                case .period:
                    Picker("Period", selection: $model.period) {
                        ForEach(DataUsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("dataUsage.periodOptions")
                case .category:
                    Picker("Category", selection: $model.category) {
                        ForEach(DataUsageCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("dataUsage.categoryOptions")
                }
            }
            .appGroupedList()
            .navigationTitle(sheet == .period ? Text("Period") : Text("Category"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { SheetCloseToolbar() }
        }
        .appSheet(detents: [.medium])
    }
}

/// 點一台主機:收到、送出、行動網路與 30 天合計。
private struct DataUsageHostSheet: View {
    let model: DataUsageModel
    let hostID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let detail = model.detail(forHost: hostID)
            let row = model.hostRows.first { $0.id == hostID }
            List {
                Group {
                    Section {
                        LabeledContent("Received", value: DataUsageFormat.bytes(detail?.received ?? 0))
                        LabeledContent("Sent", value: DataUsageFormat.bytes(detail?.sent ?? 0))
                        LabeledContent("Cellular", value: DataUsageFormat.bytes(detail?.cellular ?? 0))
                    } header: {
                        Text(model.period.hostsHeader).foregroundStyle(.secondaryText)
                    }
                    Section {
                        LabeledContent("Total", value: DataUsageFormat.bytes(detail?.thirtyDayTotal ?? 0))
                    } header: {
                        Text("Last 30 Days").foregroundStyle(.secondaryText)
                    }
                }
                // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
                .listRowBackground(AppSurface.groupedRow)
            }
            .appGroupedList()
            .monospacedDigit()
            .accessibilityIdentifier("dataUsage.hostDetail")
            .navigationTitle(row?.isDeleted == true ? String(localized: "Deleted Host") : (row?.name ?? ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { SheetCloseToolbar() }
        }
        .appSheet(detents: [.medium])
    }
}

/// 堆疊長條圖:一天一根,段與段之間留縫;點一根選取。
private struct DataUsageChart: View {
    let bars: [DataUsageBar]
    let selectedDay: String?
    let select: (String?) -> Void
    @State private var width: CGFloat = 0

    /// 要標籤的日期,取那天中午(長條的正中央)。右側 Y 軸標籤約佔 56pt,標籤寬約 44pt。
    private var labelDates: [Date] {
        let indices = DataUsageAxisLabels.labeledIndices(barCount: bars.count, plotWidth: Double(max(0, width - 56)), labelWidth: 44)
        return indices.compactMap { Calendar.current.date(byAdding: .hour, value: 12, to: bars[$0].date) }
    }

    /// 每個要標的日期,置中在那根長條下方。
    @ViewBuilder
    private func dayLabels(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        if let plot = proxy.plotFrame {
            let frame = geometry[plot]
            ForEach(labelDates, id: \.self) { date in
                if let x = proxy.position(forX: date) {
                    Text(date, format: .dateTime.month(.defaultDigits).day())
                        .font(.caption2).foregroundStyle(Color.secondaryText)
                        .fixedSize()
                        .position(x: frame.minX + x, y: frame.maxY + 12)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private struct Mark: Identifiable {
        var id: String { "\(bar.day)/\(segment.kind)" }
        var bar: DataUsageBar
        var segment: DataUsageSegment
        var start: Double
        var end: Double
    }

    private var marks: [Mark] {
        let peak = Double(bars.map(\.total).max() ?? 0)
        let gap = peak * 0.012
        return bars.flatMap { bar -> [Mark] in
            var base = 0.0
            return bar.segments.enumerated().map { index, segment in
                let start = base + (index == 0 ? 0 : gap)
                let end = max(base + Double(segment.bytes), start)
                base += Double(segment.bytes)
                return Mark(bar: bar, segment: segment, start: start, end: end)
            }
        }
    }

    var body: some View {
        Chart {
            ForEach(marks) { mark in
                BarMark(
                    x: .value("Day", mark.bar.date, unit: .day), yStart: .value("From", mark.start), yEnd: .value("To", mark.end),
                    width: .ratio(0.7)
                )
                .foregroundStyle(mark.segment.kind.color)
                .cornerRadius(3)
                .opacity(selectedDay == nil || selectedDay == mark.bar.day ? 1 : 0.35)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(DataUsageFormat.bytes(Int(bytes))).font(.caption2).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        }
        // X 軸(#477):標籤自己畫在每根長條正下方(內建軸的刻度對不準長條、也會丟掉最後一個標籤);
        // 天數多放不下時整數倍略過、從今天往回數(`DataUsageAxisLabels`)。
        .chartXAxis(.hidden)
        .padding(.bottom, 20)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 點一根長條:用點的位置換算成那天(不靠 chartXSelection,它在 iOS 要按住或拖曳)。
        .chartOverlay { proxy in
            GeometryReader { geometry in
                dayLabels(proxy: proxy, geometry: geometry)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geometry[plot].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        select(bars.first { Calendar.current.isDate($0.date, inSameDayAs: date) }?.day)
                    }
            }
        }
        // VoiceOver:每根念日期與各段(行動網路、Wi-Fi 等)的量。
        .accessibilityChartDescriptor(DataUsageChartDescriptor(bars: bars))
    }
}

/// 圖表的 VoiceOver 描述:X 軸是日期,每個類別(行動網路、Wi-Fi…)一條數列。
private struct DataUsageChartDescriptor: AXChartDescriptorRepresentable {
    let bars: [DataUsageBar]

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = bars.map { $0.date.formatted(.dateTime.month().day()) }
        let peak = max(Double(bars.map(\.total).max() ?? 0), 1)
        let xAxis = AXCategoricalDataAxisDescriptor(title: String(localized: "Day"), categoryOrder: labels)
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Data Usage"), range: 0...peak, gridlinePositions: []
        ) { DataUsageFormat.bytes(Int($0)) }
        var kinds: [DataUsageSegment.Kind] = []
        for kind in bars.flatMap({ $0.segments.map(\.kind) }) where !kinds.contains(kind) { kinds.append(kind) }
        let series = kinds.map { kind in
            AXDataSeriesDescriptor(
                name: kind.title, isContinuous: false,
                dataPoints: bars.enumerated().map { index, bar in
                    AXDataPoint(x: labels[index], y: Double(bar.segments.first { $0.kind == kind }?.bytes ?? 0))
                })
        }
        return AXChartDescriptor(
            title: String(localized: "Data Usage"), summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [],
            series: series.isEmpty ? [AXDataSeriesDescriptor(name: String(localized: "Total"), isContinuous: false, dataPoints: [])] : series)
    }
}

// MARK: - 文字與顏色

enum DataUsageFormat {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .decimal)
    }
}

extension DataUsagePeriod {
    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        }
    }

    var hostsHeader: LocalizedStringKey {
        switch self {
        case .today: "Hosts · Today"
        case .week: "Hosts · 7 Days"
        case .month: "Hosts · 30 Days"
        }
    }
}

extension DataUsageCategory {
    var title: LocalizedStringKey {
        switch self {
        case .total: "Total"
        case .network: "Wi-Fi & Cellular"
        case .direction: "Sent & Received"
        }
    }

    var legendKinds: [DataUsageSegment.Kind] {
        switch self {
        case .total: [.total]
        case .network: [.cellular, .wifi, .other]
        case .direction: [.received, .sent]
        }
    }
}

extension DataUsageSegment.Kind {
    var title: String {
        switch self {
        case .total: String(localized: "Total")
        case .cellular: String(localized: "Cellular")
        case .wifi: String(localized: "Wi-Fi")
        case .other: String(localized: "Other")
        case .sent: String(localized: "Sent")
        case .received: String(localized: "Received")
        }
    }

    var color: Color {
        switch self {
        case .total, .cellular, .received: AccessibleColors.dataUsageCellular.color
        case .wifi, .sent: AccessibleColors.dataUsageWifi.color
        case .other: DataUsageColors.neutral
        }
    }
}

private enum DataUsageColors {
    #if canImport(UIKit)
    static let groupedBackground = AppSurface.groupedPage
    static let neutral = Color(uiColor: .systemGray)
    #else
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
    static let neutral = Color.gray
    #endif
}
