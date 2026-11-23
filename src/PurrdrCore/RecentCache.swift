import Foundation

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
