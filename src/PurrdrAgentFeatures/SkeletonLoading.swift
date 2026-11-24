import Foundation

/// 骨架畫面(#496)的載入狀態機:各畫面的 model 與畫面共用的決定,不含 SwiftUI。
public enum SkeletonLoading {
    /// 沒有上次紀錄時的骨架列數。
    public static let defaultRowCount = 6
    /// 列數的範圍:太少看不出是清單、太多佔滿畫面也沒意義。
    public static let rowCountRange = 3...8

    /// 只在「第一次載入、沒有任何內容」時顯示骨架;有內容(快取或上次的資料)直接顯示內容。
    public static func isShown(isLoading: Bool, hasContent: Bool) -> Bool {
        isLoading && !hasContent
    }

    /// 骨架的列數:取上次清單的列數,夾在範圍內;沒有紀錄或上次是空的用預設。
    public static func rowCount(lastCount: Int?) -> Int {
        guard let lastCount, lastCount > 0 else { return defaultRowCount }
        return min(max(lastCount, rowCountRange.lowerBound), rowCountRange.upperBound)
    }

    /// 脈動的條件:沒開「減少動態效果」、動畫沒被關掉(UI 測試,免得重複動畫讓 XCUITest 等不到閒置)、app 在前景(進背景要停)。
    public static func pulses(reduceMotion: Bool, animationsEnabled: Bool, isActive: Bool) -> Bool {
        !reduceMotion && animationsEnabled && isActive
    }

    /// 脈動週期(秒)與最低不透明度:opacity 0.55 ↔ 1(設計稿 `Skeleton`)。
    public static let pulseDuration: Double = 1.6
    public static let pulseLowOpacity: Double = 0.55
}

/// 哪一個清單的列數要記住。
public enum SkeletonList: String, Sendable {
    case agentList
    case files
    case newChatSessions
}

/// 各清單上次的列數(只在這支裝置)。
@MainActor
public protocol SkeletonRowCountStore: AnyObject {
    func load(_ list: SkeletonList) -> Int?
    func save(_ count: Int, for list: SkeletonList)
}

@MainActor
public final class InMemorySkeletonRowCountStore: SkeletonRowCountStore {
    private var counts: [SkeletonList: Int] = [:]
    public init() {}
    public func load(_ list: SkeletonList) -> Int? { counts[list] }
    public func save(_ count: Int, for list: SkeletonList) { counts[list] = count }
}

@MainActor
public final class UserDefaultsSkeletonRowCountStore: SkeletonRowCountStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load(_ list: SkeletonList) -> Int? {
        let value = defaults.integer(forKey: "skeleton.rows.\(list.rawValue)")
        return value > 0 ? value : nil
    }
    public func save(_ count: Int, for list: SkeletonList) {
        defaults.set(count, forKey: "skeleton.rows.\(list.rawValue)")
    }
}
