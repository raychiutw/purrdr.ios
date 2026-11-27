import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 「已用／剩餘」全域設定(#389、#393):同時套用到 5 小時、7 天與 context,跨重啟保存,預設已用(#420)。
/// 存在 `PlanUsageModel.Display.storageKey`(設定 tab 與方案用量頁讀寫同一個 key);整個 app 共用一份(`HostsModel.usageDisplay`),
/// 設定 tab 改了這份也跟著變,所以用量區與 context 立即更新。`defaults` 為 `nil` 時只在記憶體(測試)。
@MainActor
@Observable
public final class UsageDisplaySetting {
    public var display: PlanUsageModel.Display {
        didSet {
            guard display != oldValue, let defaults else { return }
            display.store(in: defaults)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        display = defaults.map(PlanUsageModel.Display.stored(in:)) ?? .used
    }

    /// 依設定換算要顯示的整數百分比(`used` 是已用比例)。
    public func shownPercent(forUsed used: Int) -> Int {
        let clamped = min(max(used, 0), 100)
        return display == .used ? clamped : 100 - clamped
    }
}

/// 用量區的 model(#389):面板(單一 Agent)與主機 tab(Claude 與 Codex)共用。
/// 每個 Agent 各自查詢、各自有狀態;沒有任何來源(HTTPS 主機的主機服務不支援)時整區是說明。
@MainActor
@Observable
public final class UsageSectionModel {
    /// 一個 Agent 的顯示狀態。
    public enum EntryState: Equatable {
        case loading
        /// 至少有一個還沒到重設時間的用量週期。
        case rows
        /// 還沒回報過,或所有用量週期都已過重設時間。
        case noData
        /// 主機還沒同意包裝腳本:顯示「啟用用量顯示」。
        case needsEnable
        case failed(PlanUsageFailure)
    }

    public struct Entry: Equatable, Identifiable {
        public var agent: AgentID
        public var state: EntryState
        public var rows: [PlanUsageRow]
        /// 資料超過 10 分鐘:距今幾分鐘(畫面標「N 分鐘前」)。
        public var staleMinutes: Int?
        public var id: AgentID { agent }
    }

    private enum Raw {
        case loading
        case loaded(PlanUsage)
        case noData
        case needsEnable
        case failed(PlanUsageFailure)
    }

    public let hostName: String
    public let displaySetting: UsageDisplaySetting
    public let agents: [AgentID]
    /// 目前模型所屬的群組(聊天面板傳入;Antigravity 同一用量週期依群組有多份,只列這個群組,#448)。`nil` 用來源回報的。
    public var activeGroup: PlanUsage.Group?

    private let source: (AgentID) -> PlanUsageSource?
    private let now: () -> Date
    private let sleep: Sleep
    private var raw: [AgentID: Raw] = [:]
    /// 最後一次讀取失敗、仍顯示先前讀到的資料的 Agent(#392:主機離線時保留最後的資料)。
    private var keptAfterFailure: Set<AgentID> = []
    /// 主機 tab 只列主機上偵測到的 Agent(#465):偵測到的記下來,沒偵測到或失敗的不列、下次出現再偵測。
    public let detectsInstallation: Bool
    private var detected: Set<AgentID> = []
    private var queries: [AgentID: Task<Void, Never>] = [:]
    private var automaticRefresh: Task<Void, Never>?

    public init(
        hostName: String, agents: [AgentID], display: UsageDisplaySetting, now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = Sleeping.task, detectsInstallation: Bool = false, source: @escaping (AgentID) -> PlanUsageSource?
    ) {
        self.detectsInstallation = detectsInstallation
        self.hostName = hostName
        self.agents = agents
        displaySetting = display
        self.now = now
        self.sleep = sleep
        self.source = source
    }

    /// 目前顯示的是主機離線前最後讀到的資料。
    public var isShowingLastKnownData: Bool { !keptAfterFailure.isEmpty }

    /// 顯示中的資料最後被擷取的時間(多個 Agent 取最新的)。
    public var lastCapturedAt: Date? {
        agents.compactMap { agent -> Date? in
            if case .loaded(let usage)? = raw[agent] { return usage.capturedAt }
            return nil
        }.max()
    }

    /// 這台主機沒有用量來源(沒有任何來源:整區顯示說明)。
    public var isUnsupported: Bool { agents.allSatisfy { source($0) == nil } }

    /// 有來源的 Agent 與它們的狀態(依傳入順序)。
    public var entries: [Entry] {
        let display = displaySetting.display
        return agents.compactMap { agent in
            guard let source = source(agent), isListed(agent, source) else { return nil }
            switch raw[agent] ?? .loading {
            case .loading: return Entry(agent: agent, state: .loading, rows: [], staleMinutes: nil)
            case .noData: return Entry(agent: agent, state: .noData, rows: [], staleMinutes: nil)
            case .needsEnable: return Entry(agent: agent, state: .needsEnable, rows: [], staleMinutes: nil)
            case .failed(let failure): return Entry(agent: agent, state: .failed(failure), rows: [], staleMinutes: nil)
            case .loaded(let usage):
                let rows = PlanUsagePresentation.rows(for: usage, showing: display, now: now(), activeGroup: activeGroup)
                guard !rows.isEmpty else { return Entry(agent: agent, state: .noData, rows: [], staleMinutes: nil) }
                return Entry(agent: agent, state: .rows, rows: rows, staleMinutes: PlanUsagePresentation.staleMinutes(usage, now: now()))
            }
        }
    }

    /// 要偵測的 Agent 還沒偵測到就不列。
    private func isListed(_ agent: AgentID, _ source: PlanUsageSource) -> Bool {
        !detectsInstallation || source.installed == nil || detected.contains(agent)
    }

    /// 畫面出現:查一次;每個來源都不耗 token 與傳輸時,畫面開著定期重整。
    public func appeared() {
        stop()
        startQueries()
        let sources = agents.compactMap(source)
        guard !sources.isEmpty, sources.allSatisfy(\.cost.refreshesAutomatically) else { return }
        let sleep = sleep
        automaticRefresh = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(PlanUsageModel.automaticRefreshInterval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    public func disappeared() {
        stop()
    }

    /// 下拉重新整理:不另外送出進行中的查詢。
    public func refresh() async {
        startQueries()
        await untilIdle()
    }

    public func untilIdle() async {
        for query in Array(queries.values) { await query.value }
    }

    private func stop() {
        for query in queries.values { query.cancel() }
        queries = [:]
        automaticRefresh?.cancel()
        automaticRefresh = nil
    }

    private func startQueries() {
        for agent in agents where queries[agent] == nil {
            guard let source = source(agent) else { continue }
            if !isListed(agent, source), let installed = source.installed {
                detect(agent, installed)
                continue
            }
            if let hostWrite = source.hostWrite, !hostWrite.isGranted() {
                raw[agent] = .needsEnable
                continue
            }
            query(agent, source)
        }
    }

    /// 唯讀偵測主機上有沒有這個 Agent;偵測到才開始查用量,沒有或失敗就不列。
    private func detect(_ agent: AgentID, _ installed: @escaping @Sendable () async throws -> Bool) {
        queries[agent] = Task { [weak self] in
            let found = (try? await installed()) ?? false
            guard let self, !Task.isCancelled else { return }
            queries[agent] = nil
            guard found else { return }
            detected.insert(agent)
            startQueries()
        }
    }

    private func query(_ agent: AgentID, _ source: PlanUsageSource) {
        queries[agent] = Task { [weak self] in
            let outcome: Result<PlanUsage?, any Error>
            do {
                outcome = .success(try await source.read())
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            queries[agent] = nil
            switch outcome {
            case .success(let usage?):
                raw[agent] = .loaded(usage)
                keptAfterFailure.remove(agent)
            case .success(nil):
                raw[agent] = .noData
                keptAfterFailure.remove(agent)
            case .failure(let error):
                // 先前讀到過的資料留著(主機離線時仍看得到最後的用量),標示是最後的資料。
                if case .loaded? = raw[agent], !(error is CancellationError) {
                    keptAfterFailure.insert(agent)
                } else {
                    raw[agent] = .failed(PlanUsageFailure(error, agent: agent))
                    keptAfterFailure.remove(agent)
                }
            }
        }
    }
}
