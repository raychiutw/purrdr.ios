import Foundation

/// 加入 sheet 裡最近照片的選取狀態(#386):依點選順序編號，受剩餘附件額度限制。
public struct AttachSelection: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case selected, deselected, overLimit }

    public private(set) var ids: [String] = []

    public init() {}

    public var count: Int { ids.count }

    /// 這張照片的選取編號(從 1 起);沒選時是 `nil`。
    public func number(of id: String) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    /// 點一張照片:已選就取消，未選且還有額度就加入，否則不動並回報超量。
    @discardableResult
    public mutating func toggle(_ id: String, limit: Int) -> Outcome {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            return .deselected
        }
        guard ids.count < limit else { return .overLimit }
        ids.append(id)
        return .selected
    }
}
