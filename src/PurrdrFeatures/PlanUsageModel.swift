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

/// 方案用量畫面的 model(#176、#177)。
@MainActor
@Observable
public final class PlanUsageModel {
    public enum State: Equatable {
        case loading
        case loaded(PlanUsage)
    }

    public enum Display: Equatable { case remaining, used }

    public private(set) var state: State = .loading
    public private(set) var host: HostSelection
    public private(set) var agent: PlanUsageAgent
    public var display: Display = .remaining
    public let hosts: [PlanUsageHostOption]

    private let source: (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    private let now: () -> Date
    private let sleep: Sleep

    /// - Parameters:
    ///   - fallback: 沒有上次選擇(或那台主機已刪除)時選的主機。
    ///   - sleep: 定期重整的等待;測試注入假的。
    ///   - source: 某台主機某種 Agent 的來源;`nil` 表示這種連線方式不支援。
    public init(
        hosts: [PlanUsageHostOption], fallback: HostSelection, now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = Sleeping.task,
        source: @escaping (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    ) {
        self.hosts = hosts
        self.source = source
        self.now = now
        self.sleep = sleep
        host = fallback
        agent = .claudeCode
    }

    /// 要顯示的用量週期(已過重置時間的不顯示)。
    public var rows: [PlanUsageRow] {
        guard case .loaded(let usage) = state else { return [] }
        return PlanUsagePresentation.rows(for: usage, showing: display, now: now())
    }

    private var query: Task<Void, Never>?

    /// 畫面出現：依目前的選擇查一次。
    public func appeared() {
        startQuery()
    }

    /// 離開畫面：取消進行中的查詢，不再連線。
    public func disappeared() {
        query?.cancel()
        query = nil
    }

    /// 改選主機：新的查詢取代進行中的。
    public func select(host: HostSelection) {
        guard host != self.host else { return }
        self.host = host
        restart()
    }

    /// 改選 Agent。
    public func select(agent: PlanUsageAgent) {
        guard agent != self.agent else { return }
        self.agent = agent
        restart()
    }

    private func restart() {
        query?.cancel()
        state = .loading
        startQuery()
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
