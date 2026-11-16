import Foundation
import Observation
import PurrdrCore

/// 列表底部「Claude 用量」的 model(行為規格 F18)。
@MainActor
@Observable
public final class ClaudeUsageModel {
    public enum State: Equatable {
        /// 還沒同意(或已關閉)。
        case off
        /// 同意前檢查主機中。
        case checking
        /// 等使用者確認：會以 `user` 修改主機上的設定。
        case confirming(user: String)
        case installing
        case on
        case turningOff
    }

    public enum Display: Equatable { case remaining, used }

    public private(set) var state: State = .off
    public private(set) var usage: ClaudeUsage?
    public private(set) var message: String?
    public var display: Display = .remaining

    /// 前景、可見時讀用量的間隔(行為規格 §12:約 5 秒)。
    static let pollInterval: Duration = .seconds(5)

    private let host: ClaudeUsageHost
    private let hostID: String
    private let consent: any HostWriteConsentStore
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var feature: String { ClaudeUsageHost.feature.id }

    /// - Parameters:
    ///   - hostID: 同意以主機為單位記住。
    ///   - sleep: 輪詢的等待;測試注入假的。
    public init(host: ClaudeUsageHost, hostID: String, consent: any HostWriteConsentStore,
                now: @escaping () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.host = host
        self.hostID = hostID
        self.consent = consent
        self.now = now
        self.sleep = sleep
        state = consent.isGranted(ClaudeUsageHost.feature.id, host: hostID) ? .on : .off
    }

    /// 要顯示的視窗(已過重置時間的不顯示)。
    public var rows: [ClaudeUsageRow] {
        usage.map { ClaudeUsagePresentation.rows(for: $0, showing: display, now: now()) } ?? []
    }

    /// 用量擷取超過 10 分鐘時的擷取時間(畫面註明「截至」)。
    public var asOf: Date? { usage.flatMap { ClaudeUsagePresentation.asOf($0, now: now()) } }

    /// 使用者點「顯示 Claude 用量」:先檢查主機(設定能不能安全修改、以哪個使用者),再請使用者確認。
    public func requestUsage() async {
        guard state == .off else { return }
        message = nil
        state = .checking
        do {
            let inspection = try await host.inspect()
            state = .confirming(user: inspection.user)
        } catch {
            state = .off
            message = Self.describe(error)
        }
    }

    public func cancelConsent() {
        if case .confirming = state { state = .off }
    }

    /// 使用者確認：安裝(重新讀取設定，以最新內容為準)並記住同意。
    public func confirm() async {
        guard case .confirming = state else { return }
        state = .installing
        do {
            try await host.install()
            consent.grant(feature, host: hostID)
            state = .on
            await refresh()
        } catch {
            state = .off
            message = Self.describe(error)
        }
    }

    /// 關閉：還原主機設定，撤銷同意。還原失敗時維持開啟並說明。
    public func turnOff() async {
        guard state == .on else { return }
        state = .turningOff
        do {
            try await host.restore()
            consent.revoke(feature, host: hostID)
            usage = nil
            message = nil
            state = .off
        } catch {
            state = .on
            message = Self.describe(error)
        }
    }

    /// 讀一次用量(只在已同意時)。讀取失敗保留上次的數值。
    public func refresh() async {
        guard state == .on else { return }
        do {
            usage = try await host.readUsage()
        } catch {
            // 用量只是提示：暫時讀不到不打擾使用者，下次再讀。
        }
    }

    /// 已同意時約每 5 秒讀一次，直到所在的 task 被取消。只在畫面可見、app 在前景時執行。
    public func run() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await sleep(Self.pollInterval)
            } catch {
                return
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case ClaudeUsageError.settingsNotJSON:
            String(localized: "~/.claude/settings.json isn’t valid JSON, so Purrdr left it unchanged. Fix the file on the host and try again.")
        case ClaudeUsageError.claudeNotFound:
            String(localized: "This host user has no ~/.claude folder. Set up Claude Code on the host first.")
        case HostFilesError.changedSinceRead:
            String(localized: "~/.claude/settings.json changed while Purrdr was updating it. Nothing was changed; try again.")
        case HostWriteError.unusableFile, HostFilesError.tooLarge:
            String(localized: "Purrdr can’t safely change ~/.claude/settings.json on this host.")
        default:
            String(localized: "Couldn’t update the host: \(error.localizedDescription)")
        }
    }
}

/// 一個用量視窗的顯示內容。
public struct ClaudeUsageRow: Equatable, Sendable, Identifiable {
    public enum Window: Equatable, Sendable { case fiveHour, week }

    public var window: Window
    /// 顯示的整數百分比(剩餘或已用)。
    public var percent: Int
    /// 進度條的比例，0～1。
    public var fraction: Double
    public var resetsAt: Date?

    public var id: Window { window }
}

/// 用量的顯示規則。
public enum ClaudeUsagePresentation {
    /// 超過這麼久沒有新的擷取，就註明「截至」。
    static let staleAfter: TimeInterval = 10 * 60

    /// 5 小時在前、每週在後;已過重置時間的視窗不顯示(Claude Code 也會丟掉它)。
    public static func rows(for usage: ClaudeUsage, showing display: ClaudeUsageModel.Display, now: Date) -> [ClaudeUsageRow] {
        [(ClaudeUsageRow.Window.fiveHour, usage.fiveHour), (.week, usage.week)].compactMap { window, value in
            guard let value, value.resetsAt.map({ $0 > now }) ?? true else { return nil }
            let used = min(max(value.usedPercentage, 0), 100)
            let shown = display == .remaining ? 100 - used : used
            return ClaudeUsageRow(window: window, percent: Int(shown.rounded()), fraction: shown / 100, resetsAt: value.resetsAt)
        }
    }

    public static func asOf(_ usage: ClaudeUsage, now: Date) -> Date? {
        now.timeIntervalSince(usage.capturedAt) > staleAfter ? usage.capturedAt : nil
    }
}
