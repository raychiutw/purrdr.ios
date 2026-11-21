import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 數據用量的期間(#354):長條圖往回看幾天(含今天)。
public enum DataUsagePeriod: CaseIterable, Sendable {
    case today
    case week
    case month

    public var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }
}

/// 長條圖的分類:加總、Wi-Fi 與行動網路、送出與收到。
public enum DataUsageCategory: CaseIterable, Sendable {
    case total
    case network
    case direction
}

/// 摘要方塊的數字:總量與其中行動網路的量(位元組)。
public struct DataUsageSummary: Equatable, Sendable {
    public var total: Int
    public var cellular: Int

    public init(total: Int, cellular: Int) {
        self.total = total
        self.cellular = cellular
    }
}

/// 長條圖裡一段(堆疊的一層)。
public struct DataUsageSegment: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case total, cellular, wifi, other, sent, received
    }

    public var kind: Kind
    public var bytes: Int

    public init(kind: Kind, bytes: Int) {
        self.kind = kind
        self.bytes = bytes
    }
}

/// 長條圖的一根(一天)。`segments` 由下往上堆疊，只含有量的段。
public struct DataUsageBar: Identifiable, Equatable, Sendable {
    /// `yyyy-MM-dd`(本地時區)。
    public var day: String
    /// 那天的本地午夜。
    public var date: Date
    public var segments: [DataUsageSegment]
    /// 那天的總量(與分類無關)。
    public var total: Int
    public var id: String { day }
}

/// 主機列表的一列:期間內的用量。
public struct DataUsageHostRow: Identifiable, Equatable, Sendable {
    /// 計量用的主機 id(`HostSelection.storedValue`)。
    public var id: String
    /// 已刪除的主機是空字串，畫面顯示「已刪除的主機」。
    public var name: String
    public var icon: HostIcon
    public var isDeleted: Bool
    public var bytes: TrafficBytes
    public var cellular: Int
}

/// 點一台主機的明細(期間內)。
public struct DataUsageHostDetail: Equatable, Sendable {
    public var received: Int
    public var sent: Int
    public var cellular: Int
    /// 最近 30 天的合計(與期間無關)。
    public var thirtyDayTotal: Int
}

/// 數據用量頁的 model(#354,spec #337):讀流量計量(#353),依期間、分類與主機組出摘要、長條圖與主機列表。
///
/// 標題的主機就是全 app 的目前主機(#334):預設所有主機(`nil`)，改主機回寫目前主機。
/// 已刪除主機的歷史仍算在「所有主機」裡，列表標示已刪除。
@MainActor
@Observable
public final class DataUsageModel {
    public var period: DataUsagePeriod = .month {
        didSet { if period != oldValue { selectedDay = nil } }
    }

    public var category: DataUsageCategory = .total {
        didSet { if category != oldValue { selectedDay = nil } }
    }

    /// 目前看的主機;`nil` 是所有主機。
    public private(set) var host: HostSelection?
    public let hosts: [HostOption]
    private var selectedDay: String?
    /// 讓畫面定期重讀計量(計量本身不是被觀察的)。
    private var revision = 0
    /// 定期重讀的次數(測試觀察用)。
    public private(set) var refreshCount = 0

    private let meter: TrafficMeter
    private let currentHostChanged: (HostSelection?) -> Void
    private let now: () -> Date
    private let calendar: Calendar
    private let sleep: Sleep

    public init(
        meter: TrafficMeter, hosts: [HostOption], currentHost: HostSelection?,
        currentHostChanged: @escaping (HostSelection?) -> Void = { _ in },
        now: @escaping () -> Date = Date.init, calendar: Calendar = .current, sleep: @escaping Sleep = Sleeping.task
    ) {
        self.meter = meter
        self.hosts = hosts
        self.currentHostChanged = currentHostChanged
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
        host = currentHost.flatMap { current in hosts.contains { $0.id == current } ? current : nil }
    }

    /// 重讀計量(畫面開著時定期呼叫)。
    public func refresh() {
        revision += 1
        refreshCount += 1
    }

    /// 畫面開著時每 2 秒重讀一次,直到 task 取消。等待時間由注入的 `sleep` 決定(測試手動推進)。
    public func run() async {
        while !Task.isCancelled {
            do { try await sleep(.seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    /// 改看某台主機(`nil` 是所有主機);同時改全 app 的目前主機。
    public func selectHost(_ selection: HostSelection?) {
        if let selection, !hosts.contains(where: { $0.id == selection }) { return }
        guard selection != host else { return }
        host = selection
        selectedDay = nil
        currentHostChanged(selection)
    }

    // MARK: - 摘要

    public var sinceLaunch: DataUsageSummary {
        _ = revision
        return Self.summary(of: meter.sinceLaunch(), matching: matches)
    }

    public var today: DataUsageSummary {
        _ = revision
        return Self.summary(of: meter.today(), matching: matches)
    }

    // MARK: - 長條圖

    /// 期間內每天一根(舊到新,最後一根是今天);沒用量的天是空的。
    public var bars: [DataUsageBar] {
        _ = revision
        let byDay = Dictionary(meter.days().map { ($0.day, $0.hosts) }, uniquingKeysWith: { $1 })
        return dayKeys(count: period.days).map { key, date in
            var networks: [TrafficNetwork: TrafficBytes] = [:]
            for (hostID, traffic) in byDay[key] ?? [:] where matches(hostID) {
                for (network, bytes) in traffic { networks[network, default: TrafficBytes()] = networks[network, default: TrafficBytes()] + bytes }
            }
            return DataUsageBar(day: key, date: date, segments: segments(of: networks), total: networks.values.reduce(0) { $0 + $1.total })
        }
    }

    /// 點選的那根;換期間、分類或主機會取消。
    public var selectedBar: DataUsageBar? {
        guard let selectedDay else { return nil }
        return bars.first { $0.day == selectedDay }
    }

    /// 點一根長條選取那天;再點同一根取消;不在長條圖裡的日子不選。
    public func selectBar(day: String?) {
        guard let day, day != selectedDay, bars.contains(where: { $0.day == day }) else {
            selectedDay = nil
            return
        }
        selectedDay = day
    }

    // MARK: - 主機

    /// 期間內各主機的用量(多到少);選了某台主機時只列那台。
    public var hostRows: [DataUsageHostRow] {
        _ = revision
        let totals = hostTotals(days: period.days)
        let known = Set(hosts.map { $0.id.storedValue })
        var rows: [DataUsageHostRow] = hosts.compactMap { option in
            let id = option.id.storedValue
            let usage = totals[id]
            if option.id == .demo, usage == nil { return nil }
            return row(id: id, name: option.name, icon: option.icon, isDeleted: false, usage: usage)
        }
        for (id, usage) in totals where !known.contains(id) {
            rows.append(row(id: id, name: "", icon: .default, isDeleted: true, usage: usage))
        }
        rows = rows.filter { matches($0.id) }
        return rows.sorted { ($0.bytes.total, $1.name) > ($1.bytes.total, $0.name) }
    }

    public func detail(forHost id: String) -> DataUsageHostDetail? {
        _ = revision
        let totals = hostTotals(days: period.days)
        guard totals[id] != nil || hosts.contains(where: { $0.id.storedValue == id }) else { return nil }
        let usage = totals[id] ?? [:]
        let bytes = usage.values.reduce(TrafficBytes(), +)
        let month = hostTotals(days: DataUsagePeriod.month.days)[id]?.values.reduce(0) { $0 + $1.total } ?? 0
        return DataUsageHostDetail(
            received: bytes.received, sent: bytes.sent, cellular: usage[.cellular]?.total ?? 0, thirtyDayTotal: month)
    }

    // MARK: - 重設與說明

    /// 重設統計:清掉所有歷史與這次開啟。
    public func reset() {
        meter.reset()
        selectedDay = nil
        revision += 1
    }

    /// 統計從哪天開始(最早有資料的那天);還沒有資料時是 `nil`。
    public var countingSince: Date? {
        _ = revision
        guard let first = meter.days().first(where: { $0.hosts.values.contains { !$0.isEmpty } }) else { return nil }
        let parts = first.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - 內部

    private func matches(_ hostID: String) -> Bool {
        host.map { $0.storedValue == hostID } ?? true
    }

    private static func summary(of traffic: [String: HostTraffic], matching: (String) -> Bool) -> DataUsageSummary {
        var summary = DataUsageSummary(total: 0, cellular: 0)
        for (hostID, networks) in traffic where matching(hostID) {
            for (network, bytes) in networks {
                summary.total += bytes.total
                if network == .cellular { summary.cellular += bytes.total }
            }
        }
        return summary
    }

    private func row(id: String, name: String, icon: HostIcon, isDeleted: Bool, usage: HostTraffic?) -> DataUsageHostRow {
        let usage = usage ?? [:]
        return DataUsageHostRow(
            id: id, name: name, icon: icon, isDeleted: isDeleted, bytes: usage.values.reduce(TrafficBytes(), +),
            cellular: usage[.cellular]?.total ?? 0)
    }

    /// 期間內各主機各網路類型的用量(每台都不分過濾:列表自己過濾)。
    private func hostTotals(days count: Int) -> [String: HostTraffic] {
        let keys = Set(dayKeys(count: count).map(\.key))
        var totals: [String: HostTraffic] = [:]
        for day in meter.days() where keys.contains(day.day) {
            for (hostID, traffic) in day.hosts {
                for (network, bytes) in traffic {
                    totals[hostID, default: [:]][network] = (totals[hostID]?[network] ?? TrafficBytes()) + bytes
                }
            }
        }
        return totals
    }

    private func segments(of networks: [TrafficNetwork: TrafficBytes]) -> [DataUsageSegment] {
        let all = networks.values.reduce(TrafficBytes(), +)
        let candidates: [DataUsageSegment]
        switch category {
        case .total:
            candidates = [.init(kind: .total, bytes: all.total)]
        case .network:
            candidates = [
                .init(kind: .cellular, bytes: networks[.cellular]?.total ?? 0),
                .init(kind: .wifi, bytes: networks[.wifi]?.total ?? 0),
                .init(kind: .other, bytes: networks[.other]?.total ?? 0),
            ]
        case .direction:
            candidates = [.init(kind: .received, bytes: all.received), .init(kind: .sent, bytes: all.sent)]
        }
        return candidates.filter { $0.bytes > 0 }
    }

    /// 往回 `count` 天(含今天),舊到新。
    private func dayKeys(count: Int) -> [(key: String, date: Date)] {
        let today = calendar.startOfDay(for: now())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return (String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0), date)
        }
    }
}
