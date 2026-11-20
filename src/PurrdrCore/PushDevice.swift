import Foundation

/// 收通知的裝置種類(後台只接受這兩種)。
public enum PushDeviceModel: String, Sendable, Equatable {
    case iPhone
    case iPad
}

/// 註冊推播配對時帶給後台的這支裝置(#266):同一個 `id` 的配對歸成一台裝置。
public struct PushDeviceIdentity: Sendable, Equatable {
    /// 小寫 UUID,存在 Keychain(重裝 app 也不變)。
    public var id: String
    /// 預設是系統的裝置名稱;後台已有名稱時不覆蓋(改名以 `renamePushDevice` 為準)。
    public var name: String
    public var model: PushDeviceModel

    public init(id: String, name: String, model: PushDeviceModel) {
        self.id = id
        self.name = name
        self.model = model
    }

    /// 後台接受的名稱長度(以 Unicode code point 計，與後台相同)。
    public static let maximumNameLength = 64

    /// 去頭尾空白後 1～64 字、沒有控制字元才是合法名稱;否則回 `nil`。
    public static func validName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= maximumNameLength,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return name
    }
}

/// 會員名下會收到通知的一台裝置(`GET /v1/members/me/push-devices`)。
public struct PushDevice: Sendable, Equatable, Identifiable {
    public var id: String
    /// 舊版 app 註冊的配對沒有名稱與型號(`nil`,畫面顯示「未命名裝置」)。
    public var name: String?
    public var model: PushDeviceModel?
    /// 開了幾台主機的通知。
    public var hostCount: Int
    /// 最後一次註冊或更新配對的時間。
    public var lastRegisteredAt: Date
    /// 是不是這支裝置。
    public var isCurrent: Bool

    public init(id: String, name: String?, model: PushDeviceModel?, hostCount: Int, lastRegisteredAt: Date, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.hostCount = hostCount
        self.lastRegisteredAt = lastRegisteredAt
        self.isCurrent = isCurrent
    }
}
