import Foundation
import Observation

// 啟動提示「上次 Purrdr 意外關閉」(#632):診斷記錄裡出現新的閃退記錄時,顯示一則不打斷的橫幅。
// 每筆閃退只提示一次(已提示的時間存本機);多視窗只在一個視窗顯示;App 鎖定中不顯示。

/// 已提示過的閃退(存本機,最近 `CrashNoticeModel.maxNoticed` 筆;`reason` 不留)。
public protocol CrashNoticeStoring: AnyObject {
    var noticed: [CrashRecord] { get set }
}

public final class InMemoryCrashNoticeStore: CrashNoticeStoring {
    public var noticed: [CrashRecord]
    public init(noticed: [CrashRecord] = []) { self.noticed = noticed }
}

public final class UserDefaultsCrashNoticeStore: CrashNoticeStoring {
    private let defaults: UserDefaults
    private let key = "crashNotice.noticed"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var noticed: [CrashRecord] {
        get { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([CrashRecord].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}

@MainActor
@Observable
public final class CrashNoticeModel {
    /// 最多記住幾筆已提示的閃退(拿來比對之後才到的 MetricKit 報告)。
    public static let maxNoticed = 20

    /// 還沒提示過的閃退記錄。
    public private(set) var pending: CrashRecord?
    private var windows: [UUID] = []

    @ObservationIgnored private let recorder: DiagnosticRecorder
    @ObservationIgnored private let store: any CrashNoticeStoring

    public init(recorder: DiagnosticRecorder, store: any CrashNoticeStoring) {
        self.recorder = recorder
        self.store = store
        recorder.observeCrashes(owner: ObjectIdentifier(self)) { [weak self] record in self?.received(record) }
    }

    private func received(_ record: CrashRecord) {
        // 同一次閃退會有「中止前的標記」與「MetricKit 報告」兩筆記錄;報告的時間是整份 payload 區間的尾端,
        // 所以以區間比對(見 `CrashRecord.isSameCrash`),不比時間差。
        if store.noticed.contains(where: { record.isSameCrash(as: $0) }) { return }
        if let pending, record.isSameCrash(as: pending) { return }
        pending = record
    }

    /// 提示顯示出來時呼叫:此刻就記下「已提示」,不必等使用者按關閉(app 在提示還開著時被關掉也不重複提示)。
    public func didShow() {
        guard let pending else { return }
        var list = store.noticed
        guard !list.contains(where: { pending.isSameCrash(as: $0) }) else { return }
        var kept = pending
        kept.reasonHash = ""
        list.append(kept)
        store.noticed = Array(list.suffix(Self.maxNoticed))
    }

    public func dismiss() {
        didShow()
        pending = nil
    }

    // MARK: 多視窗

    public func attach(window: UUID) { if !windows.contains(window) { windows.append(window) } }
    public func detach(window: UUID) { windows.removeAll { $0 == window } }

    /// 只有最早開著的視窗顯示;App 鎖定中不顯示(畫面觀察鎖定狀態,解鎖後自然出現,不佔用 `AppLock.whenUnlocked`)。
    public func isShown(in window: UUID, appLocked: Bool) -> Bool {
        pending != nil && !appLocked && windows.first == window
    }

    /// 「分享記錄」:匯出整份診斷記錄(沿用設定頁的匯出)。
    public func exportFile() async -> URL? { await recorder.exportFile() }
}
