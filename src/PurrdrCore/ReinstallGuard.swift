import Foundation

/// 「這支裝置裝過新版」的標記(Seam:正式是 UserDefaults 與 Keychain 各一個,測試用記憶體)。
public protocol InstallMarker: Sendable {
    var isMarked: Bool { get }
    func mark()
}

/// 這次啟動判定的情境。
public enum ReinstallOutcome: Equatable, Sendable {
    /// 兩邊標記都在(第二次以後的啟動)。
    case normal
    /// 兩邊都沒標記(升級或全新安裝):只寫標記,不清任何資料。
    case firstLaunch
    /// UserDefaults 沒標記但 Keychain 有(App 刪除後重裝):已清掉 Keychain 殘留。
    case reinstalled
}

/// 刪 App 時 UserDefaults 一起消失、Keychain 項目卻留著:用兩個標記分辨重裝與升級。
///
/// 只有「UserDefaults 沒有、Keychain 有」才清;升級的使用者兩邊都沒標記(舊版沒寫過),只補標記,絕不清。
public struct ReinstallGuard: Sendable {
    private let defaults: any InstallMarker
    private let keychain: any InstallMarker
    private let purge: @Sendable () -> Void

    /// - Parameter purge: 清掉 App 的 Keychain 項目(不含標記本身)。
    public init(defaults: any InstallMarker, keychain: any InstallMarker, purge: @escaping @Sendable () -> Void) {
        self.defaults = defaults
        self.keychain = keychain
        self.purge = purge
    }

    /// 在任何 Keychain 存放區被讀取之前呼叫一次。
    @discardableResult
    public func run() -> ReinstallOutcome {
        let hasDefaultsMarker = defaults.isMarked
        let hasKeychainMarker = keychain.isMarked
        let outcome: ReinstallOutcome
        switch (hasDefaultsMarker, hasKeychainMarker) {
        case (true, true): return .normal
        case (false, true):
            purge()
            outcome = .reinstalled
        case (true, false), (false, false):
            outcome = .firstLaunch
        }
        defaults.mark()
        keychain.mark()
        return outcome
    }
}
