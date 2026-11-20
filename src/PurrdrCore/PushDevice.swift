import Crypto
import Foundation

/// 收通知的裝置種類(後台只接受這兩種)。
public enum PushDeviceModel: String, Sendable, Equatable {
    case iPhone
    case iPad
}

/// 這支裝置的推播 id:主機路徑 `~/.purrdr/push-<id>/` 與後台「通知裝置」共用，存在 Keychain(重裝 app 仍相同)。
public struct PushDeviceID: Hashable, Sendable, CustomStringConvertible {
    /// 主機路徑與主機服務 `device_id` 用的值。
    public let rawValue: String

    /// 只接受 1～64 個小寫英數與 `-`,且不能是 `plugin`(會拼進主機路徑)。
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 64, rawValue != "plugin",
              rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return nil }
        self.rawValue = rawValue
    }

    /// 新的 id:小寫 UUID。
    public static func generate() -> PushDeviceID {
        PushDeviceID(rawValue: UUID().uuidString.lowercased())!
    }

    /// 送後台的值(後台只收 UUID 格式):UUID 原樣;0.45 以前的 16 位 hex 等舊 id 以 SHA-256 換成固定的 UUID 格式。
    public var backendValue: String {
        if UUID(uuidString: rawValue) != nil { return rawValue }
        var hex = Substring(SHA256.hash(data: Data(rawValue.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined())
        var groups: [Substring] = []
        for length in [8, 4, 4, 4, 12] {
            groups.append(hex.prefix(length))
            hex = hex.dropFirst(length)
        }
        return groups.joined(separator: "-")
    }

    public var description: String { rawValue }
}

/// 讀不到或存不進這支裝置的推播 id(例如裝置還沒第一次解鎖);稍後再試，不換新 id。
public enum PushDeviceIDError: Error, Equatable, Sendable {
    case unreadable(status: Int32)
    case unsaved(status: Int32)
}

/// 註冊推播配對時帶給後台的這支裝置(#266):同一個 `id` 的配對歸成一台裝置。
public struct PushDeviceIdentity: Sendable, Equatable {
    public var id: PushDeviceID
    /// 預設是系統的裝置名稱;後台已有名稱時不覆蓋(改名以 `renamePushDevice` 為準)。
    public var name: String
    public var model: PushDeviceModel

    public init(id: PushDeviceID, name: String, model: PushDeviceModel) {
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
