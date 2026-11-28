import Foundation

/// 推播主機的圖示(ADR-0016、purrdr.server#45):系統圖示代號加顏色,不傳圖片。
/// 格式限制照後台:`symbol` 是 `^[A-Za-z0-9.]{1,64}$`;`color` 是 `#RRGGBB`,或字母開頭、最長 32 字元的短名稱。
/// 不合格式的值建不出來(`init?` 回 `nil`),所以送出與讀回都不會因此壞掉。
public struct PushHostIcon: Sendable, Equatable {
    public let symbol: String
    public let color: String

    public init?(symbol: String, color: String) {
        guard Self.isValid(symbol: symbol), Self.isValid(color: color) else { return nil }
        self.symbol = symbol
        self.color = color
    }

    static func isValid(symbol: String) -> Bool {
        let bytes = Array(symbol.utf8)
        return (1...64).contains(bytes.count) && bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == 0x2E }
    }

    static func isValid(color: String) -> Bool {
        let bytes = Array(color.utf8)
        if bytes.first == 0x23 {
            return bytes.count == 7 && bytes.dropFirst().allSatisfy { isDigit($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
        }
        guard let first = bytes.first, isLetter(first), bytes.count <= 32 else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == 0x2D || $0 == 0x5F }
    }

    private static func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    /// 同一個圖示(顏色的大小寫不分,後台可能正規化)。
    func isSame(as other: PushHostIcon?) -> Bool {
        guard let other else { return false }
        return symbol == other.symbol && color.lowercased() == other.color.lowercased()
    }
}

/// 一組推播配對對應主機的名稱與圖示(app 裡的顯示名稱與主機圖示;**不是機密但屬個人資料**:不寫進診斷檔或 log)。
public struct PushHostProfile: Sendable, Equatable {
    /// 已整理成後台接受的值(`sanitizedName`);沒有合格名稱是 `nil`。
    public let name: String?
    public let icon: PushHostIcon?

    public init(name: String?, icon: PushHostIcon?) {
        self.name = name.flatMap(Self.sanitizedName)
        self.icon = icon
    }

    /// 什麼都沒有可送的(沒名稱、沒圖示)。
    public var isEmpty: Bool { name == nil && icon == nil }

    /// 後台接受的名稱長度(以 Unicode code point 計)。
    public static let maximumNameLength = 64

    /// 去頭尾空白、拿掉控制字元,超過 64 個 code point 就在字元(grapheme)邊界截斷;整理後是空的回 `nil`。
    public static func sanitizedName(_ text: String) -> String? {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .control }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        var result = ""
        var count = 0
        for character in cleaned {
            let length = character.unicodeScalars.count
            guard count + length <= maximumNameLength else { break }
            result.append(character)
            count += length
        }
        return result.isEmpty ? nil : result
    }

    /// 名稱與圖示都跟後台記的一樣(後台已有的不重送)。
    public func matches(name backendName: String?, icon backendIcon: PushHostIcon?) -> Bool {
        let sameName = name == nil || name == backendName
        let sameIcon = icon == nil ? backendIcon == nil : icon!.isSame(as: backendIcon)
        return sameName && sameIcon
    }
}

/// 「通知裝置」裡一支裝置開了通知的一台主機(`GET /v1/members/me/push-devices` 的 `hosts`)。
public struct PushDeviceHost: Sendable, Equatable, Identifiable {
    /// 配對雜湊(只當清單的識別,不顯示、不記錄)。
    public var id: String
    public var name: String?
    public var icon: PushHostIcon?

    public init(id: String, name: String?, icon: PushHostIcon?) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}
