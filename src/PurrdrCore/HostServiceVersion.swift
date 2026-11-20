import Foundation

/// 各功能的最低主機服務版本與字串版本的比較;app 各處共用(型別本身在 `HostServiceFeature.swift`)。
extension HostServiceVersion {
    /// 主機服務代裝推播外掛(`push.*`)的第一個版本。
    public static let pushPlugin = "0.6.0"

    /// `installed` 是否是 `required` 或更新的版本;看不懂的版本一律當作不是。
    public static func isAtLeast(_ installed: String, _ required: String) -> Bool {
        guard let installed = HostServiceVersion(installed), let required = HostServiceVersion(required) else { return false }
        return installed >= required
    }
}
