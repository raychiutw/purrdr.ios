import Foundation

/// 聊天列表「打開時捲到底」的時機。
public enum ChatListInitialPosition {
    /// 第一次有內容的套用才需要定位到底部;空內容的套用(快取還沒到)不能把這個時機用掉。
    public static func needsScroll(hadContent: Bool, hasContent: Bool) -> Bool {
        !hadContent && hasContent
    }
}

/// 套用新內容的時機:拖曳、鍵盤動畫、選單開著時先留著,安全了再套用(spec #480)。
public enum ChatListApplyGate {
    /// 第一次套用一律立刻做(此時畫面上還沒有東西可以被打斷)。
    public static func shouldDefer(isFirstApply: Bool, isUserDriven: Bool, isKeyboardAnimating: Bool, isMenuOpen: Bool) -> Bool {
        guard !isFirstApply else { return false }
        return isUserDriven || isKeyboardAnimating || isMenuOpen
    }
}

/// 列表延伸到玻璃導覽列、橫幅與輸入列底下時,交給 `contentInset` 的上下留白(DESIGN.md:內容從玻璃底下捲過去)。
public enum ChatListInsetMath {
    /// 列表框與「避開玻璃控制後的安全區域框」(同一個座標系)的差;安全區域框超出列表時不出現負值。
    public static func insets(listMinY: Double, listMaxY: Double, safeMinY: Double, safeMaxY: Double) -> (top: Double, bottom: Double) {
        (max(0, safeMinY - listMinY), max(0, listMaxY - safeMaxY))
    }
}

/// 依最近使用順序保留固定數量的值(聊天的記憶體快取,打開聊天時同步取用)。
public struct RecentCache<Value: Sendable>: Sendable {
    public let capacity: Int
    private var values: [String: Value] = [:]
    /// 由舊到新。
    private var order: [String] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { values.count }

    /// 取值並把它當成剛用過。
    public mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// 只看不更新使用順序。
    public func peek(_ key: String) -> Value? { values[key] }

    public mutating func set(_ value: Value, for key: String) {
        values[key] = value
        touch(key)
        while order.count > capacity {
            values[order.removeFirst()] = nil
        }
    }

    public mutating func remove(_ key: String) {
        values[key] = nil
        order.removeAll { $0 == key }
    }

    public mutating func removeAll(keyPrefix prefix: String) {
        let doomed = order.filter { $0.hasPrefix(prefix) }
        for key in doomed {
            remove(key)
        }
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
