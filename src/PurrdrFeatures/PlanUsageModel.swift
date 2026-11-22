import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 方案用量畫面可以查的 Agent 種類。
public enum PlanUsageAgent: String, CaseIterable, Sendable {
    case claudeCode
    case codex
    case antigravity

    /// 主機服務(HTTPS 主機)有這個 Agent 的方案用量;Antigravity 的 statusline 包裝只有 SSH(#448)。
    var supportsHostService: Bool { self != .antigravity }
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
    /// 主機上已裝的包裝是不是舊版(最近一次讀取時看到的,不碰主機);`nil` 時不檢查(#388)。
    public var isOutdated: (@Sendable () async -> Bool)?

    public init(
        isGranted: @escaping @Sendable () -> Bool, inspect: @escaping @Sendable () async throws -> String,
        install: @escaping @Sendable () async throws -> Void, restore: @escaping @Sendable () async throws -> Void,
        isOutdated: (@Sendable () async -> Bool)? = nil
    ) {
        self.isOutdated = isOutdated
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
            },
            isOutdated: { await host.lastReadFoundOutdatedWrapper() })
        return PlanUsageSource(cost: cost, hostWrite: hostWrite) { try await host.readPlanUsage()?.planUsage }
    }
}

extension PlanUsageSource {
    /// Antigravity:讀包裝腳本存下的 `usage.json`(零 token;要經同意寫主機,ADR-0002)。
    public static func antigravity(
        channel: any HostChannel, files: HostFiles? = nil, cost: PlanUsageQueryCost, hostID: String, consent: any HostWriteConsentStore
    ) -> PlanUsageSource {
        let host = AntigravityPlanUsageHost(channel: channel, files: files)
        let feature = AntigravityPlanUsageHost.feature.id
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
        return PlanUsageSource(cost: cost, hostWrite: hostWrite) { try await host.readPlanUsage() }
    }

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

    public enum Display: String, Equatable, Sendable {
        case remaining, used

        /// 設定 tab「用量顯示」存的 key(#393);設定與方案用量畫面讀同一個。
        public static let storageKey = "planUsage.display"

        /// 存著的選擇;沒存過或讀不懂是「已用」(#420)。
        public static func stored(in defaults: UserDefaults) -> Display {
            defaults.string(forKey: storageKey).flatMap(Display.init(rawValue:)) ?? .used
        }

        public func store(in defaults: UserDefaults) {
            defaults.set(rawValue, forKey: Self.storageKey)
        }
    }

    public private(set) var state: State = .loading
    public private(set) var host: HostSelection
    public private(set) var agent: PlanUsageAgent
    /// 已用或剩餘(全域偏好,在設定 tab 改;這裡只讀,畫面每次出現時重讀)。
    public private(set) var display: Display
    /// 同意或關閉失敗的說明。
    public private(set) var message: String?
    public let hosts: [HostOption]

    private let source: (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    private let store: any PlanUsageSelectionStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let sleep: Sleep

    /// - Parameters:
    ///   - currentHost: 目前主機(#334);有值就優先;在這裡改主機不回寫。
    ///   - initialAgent: 從用量區的「啟用用量顯示」進來時,直接選那個 Agent。
    ///   - fallback: 沒有上次選擇(或那台主機已刪除)時選的主機。
    ///   - sleep: 定期重整的等待;測試注入假的。
    ///   - source: 某台主機某種 Agent 的來源;`nil` 表示這種連線方式不支援。
    public init(
        hosts: [HostOption], fallback: HostSelection, store: any PlanUsageSelectionStore,
        currentHost: HostSelection? = nil, 
        initialAgent: PlanUsageAgent? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = Sleeping.task,
        defaults: UserDefaults = .standard,
        source: @escaping (HostSelection, PlanUsageAgent) -> PlanUsageSource?
    ) {
        self.hosts = hosts
        self.source = source
        self.store = store
        self.defaults = defaults
        display = Display.stored(in: defaults)
        self.now = now
        self.sleep = sleep
        let savedSelection = store.load()
        let remembered = savedSelection.map(\.host).flatMap { savedHost in hosts.contains { $0.id == savedHost } ? savedHost : nil }
        // 目前主機有值就優先(#334);所有主機時用上次在這裡選的。
        host = currentHost.flatMap { current in hosts.contains { $0.id == current } ? current : nil } ?? remembered ?? fallback
        agent = initialAgent ?? savedSelection?.agent ?? .claudeCode
    }

    /// 要顯示的用量週期(已過重置時間的不顯示)。
    public var rows: [PlanUsageRow] {
        guard case .loaded(let usage) = state else { return [] }
        return PlanUsagePresentation.rows(for: usage, showing: display, now: now(), allGroups: true)
    }

    /// 詳細面板依模型群組分列(Claude、Codex 只有一個 `.general`)。
    public var rowGroups: [(group: PlanUsage.Group, rows: [PlanUsageRow])] {
        var result: [(group: PlanUsage.Group, rows: [PlanUsageRow])] = []
        for row in rows {
            if let index = result.firstIndex(where: { $0.group == row.group }) {
                result[index].rows.append(row)
            } else {
                result.append((row.group, [row]))
            }
        }
        return result
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
        display = Display.stored(in: defaults)
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
            message = Self.describe(error, agent: agent)
        }
    }

    public func cancelConsent() {
        guard case .confirming = state else { return }
        // 已同意的主機(更新舊包裝時取消):回到用量畫面。
        if source(host, agent)?.hostWrite?.isGranted() == true {
            state = .loading
            startQuery()
        } else {
            state = .needsConsent
        }
    }

    /// 主機上已裝的 Claude 用量包裝是舊版(例如舊的 Windows 版會在原 status line 的輸入前多一個 BOM):提示重新安裝。
    /// 不會靜默覆寫:要經 `requestWrapperUpdate()` → 使用者確認 → `confirm()`,與第一次安裝同一個同意流程(#388)。
    public private(set) var wrapperUpdateAvailable = false

    /// 使用者要更新舊的包裝:同意前的檢查,再請使用者確認(安裝可重複執行,只換掉腳本)。
    public func requestWrapperUpdate() async {
        guard wrapperUpdateAvailable, canTurnOff, let hostWrite = source(host, agent)?.hostWrite else { return }
        message = nil
        query?.cancel()
        query = nil
        let previous = state
        state = .checking
        await whileSelected(hostWrite.inspect) { user in
            state = .confirming(user: user)
        } failure: { error in
            state = previous
            message = Self.describe(error, agent: agent)
        }
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
            message = Self.describe(error, agent: agent)
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
            wrapperUpdateAvailable = false
            state = .needsConsent
        } failure: { error in
            state = previous
            message = Self.describe(error, agent: agent)
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

    static func describe(_ error: any Error, agent: PlanUsageAgent) -> String {
        switch error {
        case ClaudeUsageError.settingsNotJSON:
            String(localized: "Claude Code’s settings on this host are damaged, so Purrdr left them unchanged. Fix them there and try again.")
        case ClaudeUsageError.claudeNotFound:
            String(localized: "Claude Code isn’t set up on this host. Set it up there first.")
        case AntigravityUsageError.settingsNotJSON:
            String(localized: "Antigravity’s settings on this host are damaged, so Purrdr left them unchanged. Fix them there and try again.")
        case AntigravityUsageError.antigravityNotFound:
            String(localized: "Antigravity isn’t set up on this host. Set it up there first.")
        case AntigravityUsageError.windowsUnsupported:
            String(localized: "Antigravity plan usage isn’t available on Windows hosts yet.")
        case HostFilesError.changedSinceRead:
            agent == .antigravity
                ? String(localized: "Antigravity’s settings changed while Purrdr was updating them. Nothing was changed; try again.")
                : String(localized: "Claude Code’s settings changed while Purrdr was updating them. Nothing was changed; try again.")
        case HostWriteError.unusableFile, HostFilesError.tooLarge:
            agent == .antigravity
                ? String(localized: "Purrdr can’t safely change Antigravity’s settings on this host.")
                : String(localized: "Purrdr can’t safely change Claude Code’s settings on this host.")
        default:
            String(localized: "Couldn’t update the host: \(error.localizedDescription)")
        }
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
        message = nil
        wrapperUpdateAvailable = false
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
            if case .success = outcome { wrapperUpdateAvailable = await source.hostWrite?.isOutdated?() ?? false }
        }
    }
}

/// 一個用量週期的顯示內容。
public struct PlanUsageRow: Equatable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public var group: PlanUsage.Group
        public var period: PlanUsage.Period.Kind
    }

    public var period: PlanUsage.Period.Kind
    /// 模型群組(Antigravity 同一個用量週期有 Gemini 與第三方兩份,#448);其他 Agent 是 `.general`。
    public var group: PlanUsage.Group = .general
    /// 顯示的整數百分比(剩餘或已用)。
    public var percent: Int
    /// 圓環的比例，0～1。
    public var fraction: Double
    public var resetsAt: Date?
    /// 圓環與進度條顏色的分級(依已用比例,與顯示已用或剩餘無關)。
    public var level: PlanUsageLevel

    /// 到門檻(已用 70% 起)就加警示三角,不只靠顏色(#389)。
    public var showsWarning: Bool { level != .ample }

    public var id: ID { ID(group: group, period: period) }
}

/// 依已用比例分的三級:70% 起偏高、85% 起將用完(同 context 的級距,DESIGN.md「低飽和用量色」)。
public enum PlanUsageLevel: Equatable, Sendable { case ample, low, depleted }

/// 方案用量的顯示規則。
public enum PlanUsagePresentation {
    /// - Parameters:
    ///   - allGroups: 詳細面板:所有模型群組都列;標題與主機 tab 只列目前模型的群組。
    ///   - activeGroup: 目前模型所屬群組(聊天的模型),優先於來源回報的;都沒有時列第一個群組,兩組不混在一起。
    public static func rows(
        for usage: PlanUsage, showing display: PlanUsageModel.Display, now: Date, allGroups: Bool = false,
        activeGroup: PlanUsage.Group? = nil
    ) -> [PlanUsageRow] {
        var periods = usage.periods
        let groups = periods.reduce(into: [PlanUsage.Group]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        if !allGroups, groups.count > 1 {
            let wanted = [activeGroup, usage.activeGroup].compactMap { $0 }.first(where: groups.contains) ?? groups[0]
            periods = periods.filter { $0.group == wanted }
        }
        return periods.compactMap { period in
            guard period.resetsAt.map({ $0 > now }) ?? true else { return nil }
            let used = PlanUsage.Period.clamped(period.usedPercentage)
            let remaining = 100 - used
            let shown = display == .remaining ? remaining : used
            return PlanUsageRow(
                period: period.kind, group: period.group, percent: Int(shown.rounded()), fraction: shown / 100, resetsAt: period.resetsAt,
                level: level(used: used))
        }
    }

    /// 超過這麼久沒有新的擷取，就註明「截至」。
    static let staleAfter: TimeInterval = 10 * 60

    /// 擷取超過 10 分鐘時的擷取時間(畫面註明「截至」)。
    public static func asOf(_ usage: PlanUsage, now: Date) -> Date? {
        now.timeIntervalSince(usage.capturedAt) > staleAfter ? usage.capturedAt : nil
    }

    /// 已用達這個比例算偏高(加警示三角)。
    static let warnFrom: Double = 70
    /// 已用達這個比例算將用完。
    static let criticalFrom: Double = 85

    static func level(used: Double) -> PlanUsageLevel {
        used >= criticalFrom ? .depleted : used >= warnFrom ? .low : .ample
    }

    /// 擷取超過 10 分鐘時,距今幾分鐘(畫面標「N 分鐘前」)。
    public static func staleMinutes(_ usage: PlanUsage, now: Date) -> Int? {
        let age = now.timeIntervalSince(usage.capturedAt)
        return age > staleAfter ? Int(age / 60) : nil
    }
}
