import Foundation
import Observation

// 啟動提示「上次 Purrdr 意外關閉」(#632):診斷記錄裡出現新的閃退記錄時,顯示一則不打斷的橫幅。
// 每筆閃退只提示一次(已提示的時間存本機);多視窗只在一個視窗顯示;App 鎖定中等解鎖後才顯示。

/// 已提示過的最新閃退時間(存本機)。
public protocol CrashNoticeStoring: AnyObject {
    var lastNoticed: Date? { get set }
}

public final class InMemoryCrashNoticeStore: CrashNoticeStoring {
    public var lastNoticed: Date?
    public init(lastNoticed: Date? = nil) { self.lastNoticed = lastNoticed }
}

public final class UserDefaultsCrashNoticeStore: CrashNoticeStoring {
    private let defaults: UserDefaults
    private let key = "crashNotice.lastNoticed"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var lastNoticed: Date? {
        get { defaults.object(forKey: key) as? Date }
        set { defaults.set(newValue, forKey: key) }
    }
}

@MainActor
@Observable
public final class CrashNoticeModel {
    /// 同一次閃退會有「中止前的標記」與「MetricKit 報告」兩筆記錄,時間差在這個範圍內視為同一次。
    public static let sameCrashWindow: TimeInterval = 600

    /// 還沒提示過的閃退記錄。
    public private(set) var pending: CrashRecord?
    /// 已經可以顯示(App 鎖已解開)。
    public private(set) var isRevealed = false
    private var windows: [UUID] = []

    @ObservationIgnored private let recorder: HitchRecorder
    @ObservationIgnored private let store: any CrashNoticeStoring

    public init(recorder: HitchRecorder, store: any CrashNoticeStoring) {
        self.recorder = recorder
        self.store = store
        recorder.observeCrashes { [weak self] record in self?.received(record) }
    }

    private func received(_ record: CrashRecord) {
        if let noticed = store.lastNoticed, record.timestamp <= noticed.addingTimeInterval(Self.sameCrashWindow) { return }
        if let pending, abs(record.timestamp.timeIntervalSince(pending.timestamp)) < Self.sameCrashWindow { return }
        pending = record
    }

    /// 解鎖後才呼叫(經 `AppLock.whenUnlocked`)。
    public func reveal() { if pending != nil { isRevealed = true } }

    public func dismiss() {
        if let pending { store.lastNoticed = max(pending.timestamp, store.lastNoticed ?? .distantPast) }
        pending = nil
        isRevealed = false
    }

    // MARK: 多視窗

    public func attach(window: UUID) { if !windows.contains(window) { windows.append(window) } }
    public func detach(window: UUID) { windows.removeAll { $0 == window } }

    /// 只有最早開著的視窗顯示。
    public func isShown(in window: UUID) -> Bool {
        pending != nil && isRevealed && windows.first == window
    }

    /// 「分享記錄」:匯出整份診斷記錄(沿用設定頁的匯出)。
    public func exportFile() async -> URL? { await recorder.exportFile() }
}
