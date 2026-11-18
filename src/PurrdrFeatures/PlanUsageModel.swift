import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 方案用量畫面可以查的 Agent 種類。
public enum PlanUsageAgent: String, CaseIterable, Sendable {
    case claudeCode
}

/// 方案用量畫面的主機選項。
public struct PlanUsageHostOption: Identifiable, Equatable, Sendable {
    public var id: HostSelection
    public var name: String
    public var icon: HostIcon

    public init(id: HostSelection, name: String, icon: HostIcon = .default) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}

/// 一台主機上一種 Agent 的方案用量來源。
public struct PlanUsageSource: Sendable {
    public var cost: PlanUsageQueryCost
    /// 查一次;Agent 還沒回報過時是 `nil`。
    public var read: @Sendable () async throws -> PlanUsage?

    public init(cost: PlanUsageQueryCost, read: @escaping @Sendable () async throws -> PlanUsage?) {
        self.cost = cost
        self.read = read
    }
}

extension PlanUsageSource {
    /// Claude Code:讀包裝腳本存下的 `usage.json`(零 token)。
    public static func claude(
        channel: any HostChannel, cost: PlanUsageQueryCost, hostID: String, consent: any HostWriteConsentStore
    ) -> PlanUsageSource {
        let host = ClaudeUsageHost(channel: channel)
        return PlanUsageSource(cost: cost) { try await host.readUsage()?.planUsage }
    }
}

/// 方案用量畫面上次選的主機與 Agent。
public struct PlanUsageSelection: Equatable, Sendable {
    public var host: HostSelection
    public var agent: PlanUsageAgent

    public init(host: HostSelection, agent: PlanUsageAgent) {
        self.host = host
        self.agent = agent
    }
}

/// 上次選擇的本機存放處。
@MainActor
public protocol PlanUsageSelectionStore: AnyObject {
    func load() -> PlanUsageSelection?
    func save(_ selection: PlanUsageSelection)
}

/// 只在記憶體：測試與 UI 測試用。
@MainActor
public final class InMemoryPlanUsageSelectionStore: PlanUsageSelectionStore {
    private var selection: PlanUsageSelection?

    public init(_ selection: PlanUsageSelection? = nil) {
        self.selection = selection
    }

    public func load() -> PlanUsageSelection? { selection }
    public func save(_ selection: PlanUsageSelection) { self.selection = selection }
}

/// 方案用量畫面的 model(#176、#177)。
@MainActor
@Observable
public final class PlanUsageModel {
    public enum State: Equatable {
        case loading
        case loaded(PlanUsage)
        /// Agent 還沒回報過方案用量。
        case noData
        /// 這種連線方式(HTTPS)不支援方案用量。
        case unsupportedConnection
        /// 查詢失敗(例如連不上主機)。
        case failed(String)
    }

    public enum Display: Equatable { case remaining, used }

    public private(set) var state: State = .loading
    public private(set) var host: HostSelection
    public private(set) var agent: PlanUsageAgent
    public var display: Display = .remaining
    public let hosts: [PlanUsageHostOption]

    private let source: (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    private let store: any PlanUsageSelectionStore
    private let now: () -> Date
    private let sleep: Sleep

    /// - Parameters:
    ///   - fallback: 沒有上次選擇(或那台主機已刪除)時選的主機。
    ///   - sleep: 定期重整的等待;測試注入假的。
    ///   - source: 某台主機某種 Agent 的來源;`nil` 表示這種連線方式不支援。
    public init(
        hosts: [PlanUsageHostOption], fallback: HostSelection, store: any PlanUsageSelectionStore,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = Sleeping.task,
        source: @escaping (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    ) {
        self.hosts = hosts
        self.source = source
        self.store = store
        self.now = now
        self.sleep = sleep
        let saved = store.load()
        host = saved.map(\.host).flatMap { saved in hosts.contains { $0.id == saved } ? saved : nil } ?? fallback
        agent = saved?.agent ?? .claudeCode
    }

    /// 要顯示的用量週期(已過重置時間的不顯示)。
    public var rows: [PlanUsageRow] {
        guard case .loaded(let usage) = state else { return [] }
        return PlanUsagePresentation.rows(for: usage, showing: display, now: now())
    }

    /// 不耗 token 也不耗傳輸的來源，畫面開著時重整的間隔。
    static let automaticRefreshInterval: Duration = .seconds(5)

    private var query: Task<Void, Never>?
    private var automaticRefresh: Task<Void, Never>?

    /// 畫面出現：依目前的選擇查一次。
    public func appeared() {
        restart()
    }

    /// 離開畫面：取消進行中的查詢，不再連線。
    public func disappeared() {
        stop()
    }

    /// 改選主機：新的查詢取代進行中的。
    public func select(host: HostSelection) {
        guard host != self.host else { return }
        self.host = host
        store.save(PlanUsageSelection(host: host, agent: agent))
        restart()
    }

    /// 改選 Agent。
    public func select(agent: PlanUsageAgent) {
        guard agent != self.agent else { return }
        self.agent = agent
        store.save(PlanUsageSelection(host: host, agent: agent))
        restart()
    }

    private func restart() {
        stop()
        state = .loading
        startQuery()
        guard source(host, agent)?.cost.refreshesAutomatically == true else { return }
        let sleep = sleep
        automaticRefresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(Self.automaticRefreshInterval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func stop() {
        query?.cancel()
        query = nil
        automaticRefresh?.cancel()
        automaticRefresh = nil
    }

    /// 下拉重新整理：查詢進行中時等它，不另外送出。
    public func refresh() async {
        if query == nil { startQuery() }
        await untilIdle()
    }

    /// 等進行中的查詢結束。
    public func untilIdle() async {
        await query?.value
    }

    private func startQuery() {
        guard let source = source(host, agent) else { return }
        query = Task { [weak self] in
            let usage = try? await source.read()
            guard let self, !Task.isCancelled else { return }
            query = nil
            if let usage { state = .loaded(usage) }
        }
    }
}

/// 一個用量週期的顯示內容。
public struct PlanUsageRow: Equatable, Sendable, Identifiable {
    public var period: PlanUsage.Period.Kind
    /// 顯示的整數百分比(剩餘或已用)。
    public var percent: Int
    /// 圓環的比例，0～1。
    public var fraction: Double
    public var resetsAt: Date?
    /// 圓環顏色的分級(依剩餘比例)。
    public var level: PlanUsageLevel

    public var id: PlanUsage.Period.Kind { period }
}

/// 依剩餘比例分的三級。
public enum PlanUsageLevel: Equatable, Sendable { case ample, low, depleted }

/// 方案用量的顯示規則。
public enum PlanUsagePresentation {
    public static func rows(for usage: PlanUsage, showing display: PlanUsageModel.Display, now: Date) -> [PlanUsageRow] {
        usage.periods.compactMap { period in
            guard period.resetsAt.map({ $0 > now }) ?? true else { return nil }
            let used = min(max(period.usedPercentage, 0), 100)
            let remaining = 100 - used
            let shown = display == .remaining ? remaining : used
            return PlanUsageRow(
                period: period.kind, percent: Int(shown.rounded()), fraction: shown / 100, resetsAt: period.resetsAt,
                level: level(remaining: remaining))
        }
    }

    /// 超過這麼久沒有新的擷取，就註明「截至」。
    static let staleAfter: TimeInterval = 10 * 60

    /// 擷取超過 10 分鐘時的擷取時間(畫面註明「截至」)。
    public static func asOf(_ usage: PlanUsage, now: Date) -> Date? {
        now.timeIntervalSince(usage.capturedAt) > staleAfter ? usage.capturedAt : nil
    }

    static func level(remaining: Double) -> PlanUsageLevel {
        remaining > 40 ? .ample : remaining > 15 ? .low : .depleted
    }
}
