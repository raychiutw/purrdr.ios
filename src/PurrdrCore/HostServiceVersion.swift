import Foundation

/// 主機服務版本(`welcome` 的 `host_service_version`)的比較與各功能的最低版本;app 各處共用。
public enum HostServiceVersion {
    /// 主機服務代裝推播外掛(`push.*`)的第一個版本。
    public static let pushPlugin = "0.6.0"

    /// `installed` 是否是 `required` 或更新的版本;看不懂的版本一律當作不是。
    public static func isAtLeast(_ installed: String, _ required: String) -> Bool {
        guard let installed = numbers(installed), let required = numbers(required) else { return false }
        return !installed.lexicographicallyPrecedes(required)
    }

    /// `1.2.3` → `[1, 2, 3]`(缺的段補 0);預發行標記(`-beta`)之後不比;看不懂是 `nil`。
    public static func numbers(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap(\.self) + Array(repeating: 0, count: 3 - parts.count)
    }
}
