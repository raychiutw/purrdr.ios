import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 方案用量畫面可以查的 Agent 種類。
public enum PlanUsageAgent: String, CaseIterable, Sendable {
    case claudeCode
    case codex
}

/// 一台主機上一種 Agent 的方案用量來源。
public struct PlanUsageSource: Sendable {
    public var cost: PlanUsageQueryCost
    /// 要先經同意修改主機設定才讀得到(Claude);`nil` 時不需要。
    public var hostWrite: PlanUsageHostWrite?
    /// 查一次;Agent 還沒回報過時是 `nil`。
    public var read: @Sendable () async throws -> PlanUsage?

    public init(
        cost: PlanUsageQueryCost, hostWrite: PlanUsageHostWrite? = nil, read: @escaping @Sendable () async throws -> PlanUsage?
    ) {
        self.cost = cost
        self.hostWrite = hostWrite
        self.read = read
    }
}

/// 經同意修改主機設定(ADR-0002):同意以主機為單位記住，關閉時完整還原。
public struct PlanUsageHostWrite: Sendable {
    public var isGranted: @Sendable () -> Bool
    /// 同意前的檢查;回傳會以哪個主機使用者修改。
    public var inspect: @Sendable () async throws -> String
    /// 安裝並記住同意。
    public var install: @Sendable () async throws -> Void
    /// 還原並撤銷同意。
    public var restore: @Sendable () async throws -> Void

    public init(
        isGranted: @escaping @Sendable () -> Bool, inspect: @escaping @Sendable () async throws -> String,
        install: @escaping @Sendable () async throws -> Void, restore: @escaping @Sendable () async throws -> Void
    ) {
        self.isGranted = isGranted
        self.inspect = inspect
        self.install = install
        self.restore = restore
    }
}

extension PlanUsageSource {
    /// Claude Code:讀包裝腳本存下的 `usage.json`(零 token)。`files` 是這台主機共用的長駐讀取(#203)。
    public static func claude(
        channel: any HostChannel, files: HostFiles? = nil, cost: PlanUsageQueryCost, hostID: String, consent: any HostWriteConsentStore
    ) -> PlanUsageSource {
        let host = ClaudePlanUsageHost(channel: channel, files: files)
        let feature = ClaudePlanUsageHost.feature.id
        let hostWrite = PlanUsageHostWrite(
            isGranted: { consent.isGranted(feature, host: hostID) },
            inspect: { try await host.inspect().user },
            install: {
                try await host.install()
                consent.grant(feature, host: hostID)
            },
            restore: {
                try await host.restore()
                consent.revoke(feature, host: hostID)
            })
        return PlanUsageSource(cost: cost, hostWrite: hostWrite) { try await host.readPlanUsage()?.planUsage }
    }
}

extension PlanUsageSource {
    /// Codex:執行一次 `codex app-server` 查詢(不寫主機、不需同意)。
    public static func codex(channel: any HostChannel, cost: PlanUsageQueryCost, sleep: @escaping Sleep = Sleeping.task) -> PlanUsageSource {
        let host = CodexPlanUsageHost(channel: channel, sleep: sleep)
        return PlanUsageSource(cost: cost) { try await host.readPlanUsage() }
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

/// 存在 `UserDefaults`(只在這支裝置)。
@MainActor
public final class UserDefaultsPlanUsageSelectionStore: PlanUsageSelectionStore {
    public static let defaultKey = "planUsageSelection"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PlanUsageSelection? {
        guard let stored = defaults.dictionary(forKey: key) as? [String: String],
              let host = stored["host"].flatMap(HostSelection.init(storedValue:)),
              let agent = stored["agent"].flatMap(PlanUsageAgent.init(rawValue:)) else { return nil }
        return PlanUsageSelection(host: host, agent: agent)
    }

    public func save(_ selection: PlanUsageSelection) {
        defaults.set(["host": selection.host.storedValue, "agent": selection.agent.rawValue], forKey: key)
    }
}

/// 查不到方案用量的原因;說明文字由畫面翻譯。
public enum PlanUsageFailure: Equatable, Sendable {
    case codexNotFound
    case codexNotSignedIn
    case codexUnreadableResponse
    /// app-server 沒有在主機指令期限內回應。
    case codexTimedOut
    /// app-server 回報查詢失敗(帶它的說明)。
    case codexRequestFailed(String)
    /// 主機連線的錯誤(已是 `HostErrorText` 的說明)。
    case connection(String)

    /// Codex 自己的錯誤與 app-server 逾時;其他是主機連線的錯誤。
    init(_ error: any Error, agent: PlanUsageAgent) {
        self = switch error {
        case CodexPlanUsageError.codexNotFound: .codexNotFound
        case CodexPlanUsageError.notSignedIn: .codexNotSignedIn
        case CodexPlanUsageError.unreadableResponse: .codexUnreadableResponse
        case CodexPlanUsageError.requestFailed(let message): .codexRequestFailed(message)
        case HostCommandError.deadlineExceeded where agent == .codex: .codexTimedOut
        default: .connection(HostErrorText.message(for: error))
        }
    }
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
        case failed(PlanUsageFailure)
        /// 要先同意修改主機設定(Claude)。
        case needsConsent
        /// 同意前檢查主機中。
        case checking
        /// 等使用者確認：會以 `user` 修改主機上的設定。
        case confirming(user: String)
        case installing
        case turningOff
    }

    public enum Display: Equatable { case remaining, used }

    public private(set) var state: State = .loading
    public private(set) var host: HostSelection
    public private(set) var agent: PlanUsageAgent
    public var display: Display = .remaining
    /// 同意或關閉失敗的說明。
    public private(set) var message: String?
    public let hosts: [HostOption]

    private let source: (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    private let store: any PlanUsageSelectionStore
    private let currentHostChanged: (HostSelection) -> Void
    private let now: () -> Date
    private let sleep: Sleep

    /// - Parameters:
    ///   - currentHost: 目前主機(#334);有值就優先，在這裡改主機也回寫。
    ///   - fallback: 沒有上次選擇(或那台主機已刪除)時選的主機。
    ///   - sleep: 定期重整的等待;測試注入假的。
    ///   - source: 某台主機某種 Agent 的來源;`nil` 表示這種連線方式不支援。
    public init(
        hosts: [HostOption], fallback: HostSelection, store: any PlanUsageSelectionStore,
        currentHost: HostSelection? = nil, currentHostChanged: @escaping (HostSelection) -> Void = { _ in },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = Sleeping.task,
        source: @escaping (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    ) {
        self.hosts = hosts
        self.source = source
        self.store = store
        self.currentHostChanged = currentHostChanged
        self.now = now
        self.sleep = sleep
        let savedSelection = store.load()
        let remembered = savedSelection.map(\.host).flatMap { savedHost in hosts.contains { $0.id == savedHost } ? savedHost : nil }
        // 目前主機有值就優先(#334);所有主機時用上次在這裡選的。
        host = currentHost.flatMap { current in hosts.contains { $0.id == current } ? current : nil } ?? remembered ?? fallback
        agent = savedSelection?.agent ?? .claudeCode
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

    private var isVisible = false
    private var isInBackground = false

    /// 畫面出現：依目前的選擇查一次。
    public func appeared() {
        isVisible = true
        restart()
    }

    /// 離開畫面：取消進行中的查詢，不再連線。
    public func disappeared() {
        isVisible = false
        stop()
    }

    /// app 進背景：不再連線。
    public func enteredBackground() {
        isInBackground = true
        if isVisible { stop() }
    }

    /// app 回到前景：只有從背景回來才算畫面再出現一次(拉下控制中心後回來不算)。
    public func becameActive() {
        guard isInBackground else { return }
        isInBackground = false
        if isVisible { restart() }
    }

    /// 目前選擇的查詢成本;這種連線方式不支援時是 `nil`。
    public var cost: PlanUsageQueryCost? { source(host, agent)?.cost }

    /// 目前的來源已同意修改主機設定，可以關閉並還原。
    public var canTurnOff: Bool {
        guard let hostWrite = source(host, agent)?.hostWrite else { return false }
        switch state {
        case .loading, .loaded, .noData, .failed: return hostWrite.isGranted()
        default: return false
        }
    }

    /// 使用者要顯示 Claude 的方案用量：先檢查主機(設定能不能安全修改、以哪個使用者),再請使用者確認。
    public func requestConsent() async {
        guard state == .needsConsent, let hostWrite = source(host, agent)?.hostWrite else { return }
        message = nil
        state = .checking
        await whileSelected(hostWrite.inspect) { user in
            state = .confirming(user: user)
        } failure: { error in
            state = .needsConsent
            message = Self.describe(error)
        }
    }

    public func cancelConsent() {
        if case .confirming = state { state = .needsConsent }
    }

    /// 使用者確認：安裝(重新讀取設定，以最新內容為準)並記住同意，再查一次。
    public func confirm() async {
        guard case .confirming = state, let hostWrite = source(host, agent)?.hostWrite else { return }
        state = .installing
        await whileSelected(hostWrite.install) {
            state = .loading
            await refresh()
        } failure: { error in
            state = .needsConsent
            message = Self.describe(error)
        }
    }

    /// 關閉這台主機的 Claude 方案用量：還原主機設定、撤銷同意。還原失敗時維持原狀並說明。
    public func turnOff() async {
        guard canTurnOff, let hostWrite = source(host, agent)?.hostWrite else { return }
        let previous = state
        // 只停進行中的查詢：定期重整在還原期間會略過，之後重新同意仍照常。
        query?.cancel()
        query = nil
        state = .turningOff
        await whileSelected(hostWrite.restore) {
            message = nil
            state = .needsConsent
        } failure: { error in
            state = previous
            message = Self.describe(error)
        }
    }

    /// 執行主機寫入;等待期間改選了主機或 Agent 時，結果不再套用。
    private func whileSelected<Value>(
        _ operation: @Sendable () async throws -> Value, success: (Value) async -> Void, failure: (any Error) -> Void
    ) async {
        let selection = PlanUsageSelection(host: host, agent: agent)
        let outcome: Result<Value, any Error>
        do {
            outcome = .success(try await operation())
        } catch {
            outcome = .failure(error)
        }
        guard selection == PlanUsageSelection(host: host, agent: agent) else { return }
        switch outcome {
        case .success(let value): await success(value)
        case .failure(let error): failure(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case ClaudeUsageError.settingsNotJSON:
            String(localized: "Claude Code’s settings on this host are damaged, so Purrdr left them unchanged. Fix them there and try again.")
        case ClaudeUsageError.claudeNotFound:
            String(localized: "Claude Code isn’t set up on this host. Set it up there first.")
        case HostFilesError.changedSinceRead:
            String(localized: "Claude Code’s settings changed while Purrdr was updating them. Nothing was changed; try again.")
        case HostWriteError.unusableFile, HostFilesError.tooLarge:
            String(localized: "Purrdr can’t safely change Claude Code’s settings on this host.")
        default:
            String(localized: "Couldn’t update the host: \(error.localizedDescription)")
        }
    }

    /// 改選主機：新的查詢取代進行中的。
    public func select(host: HostSelection) {
        guard host != self.host else { return }
        self.host = host
        store.save(PlanUsageSelection(host: host, agent: agent))
        currentHostChanged(host)
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
        message = nil
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

    /// 下拉重新整理：查詢進行中時等它，不另外送出;同意、確認、安裝、還原中不查。
    public func refresh() async {
        switch state {
        case .checking, .confirming, .installing, .turningOff: return
        default: break
        }
        if query == nil { startQuery() }
        await untilIdle()
    }

    /// 等進行中的查詢結束。
    public func untilIdle() async {
        await query?.value
    }

    private func startQuery() {
        guard let source = source(host, agent) else {
            state = .unsupportedConnection
            return
        }
        if let hostWrite = source.hostWrite, !hostWrite.isGranted() {
            state = .needsConsent
            return
        }
        query = Task { [weak self] in
            let outcome: Result<PlanUsage?, any Error>
            do {
                outcome = .success(try await source.read())
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            query = nil
            switch outcome {
            case .success(let usage?): state = .loaded(usage)
            case .success(nil): state = .noData
            case .failure(let error): state = .failed(PlanUsageFailure(error, agent: agent))
            }
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
            let used = PlanUsage.Period.clamped(period.usedPercentage)
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

    /// 剩餘超過這個比例算充足。
    static let ampleAbove: Double = 40
    /// 剩餘超過這個比例(且不算充足)算偏低，其餘算將用完。
    static let lowAbove: Double = 15

    static func level(remaining: Double) -> PlanUsageLevel {
        remaining > ampleAbove ? .ample : remaining > lowAbove ? .low : .depleted
    }
}
