import Crypto
import Foundation

/// 推播配對的密鑰(ADR-0004、GLOSSARY「推播配對」):32 bytes 亂數，以 64 位小寫 hex 表示。
///
/// 密鑰只寫到主機上(`~/.purrdr/push-<裝置>/pairing`,只有本人可讀),Purrdr 後台只拿到它的雜湊;
/// app 也不保存密鑰，只記雜湊(點通知時用來找主機、關閉時撤銷)。
public struct PushPairingKey: Sendable, Equatable, CustomStringConvertible {
    public let bytes: Data

    /// 產生新的密鑰(swift-crypto 的安全亂數)。
    public static func generate() -> PushPairingKey {
        PushPairingKey(bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    init(bytes: Data) {
        precondition(bytes.count == 32)
        self.bytes = bytes
    }

    /// 從 64 位小寫 hex 讀回;形狀不對回 `nil`。
    public init?(hex: String) {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy(Self.isLowercaseHex) else { return nil }
        var bytes = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes: bytes)
    }

    public var hex: String { Self.hex(bytes) }

    /// 交給後台的雜湊：32 bytes 的 SHA-256,小寫 hex(與 `raychiutw/purrdr.server` 的 `src/push.ts` 的 `pairingKeyHash` 相同)。
    public var hash: String { Self.hex(Data(SHA256.hash(data: bytes))) }

    /// 不印出密鑰本身(避免進 log)。
    public var description: String { "PushPairingKey(hash: \(hash.prefix(8))…)" }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func isLowercaseHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }
}

/// 主機上的推播配對檔(`~/.purrdr/push-<裝置>/pairing`):主機外掛讀它決定要不要送、送到哪、帶哪個密鑰。
///
/// 格式刻意是「一行一個 `名稱=值`」,讓外掛的 sh 與 PowerShell 不需要 JSON 解析器:
///
/// ```text
/// purrdr-push 1
/// endpoint=https://…/v1/push
/// key=<64 位 hex>
/// muted=<session 值>          (每個靜音的聊天一行，可以沒有)
/// ```
public struct PushPairingFile: Sendable, Equatable {
    public var endpoint: URL
    public var key: PushPairingKey
    /// 這支裝置靜音的聊天(Agent 的 session 值)。iOS 在 app 能攔截前就顯示推播，所以靜音只能在主機端生效(行為規格 F14)。
    public var muted: Set<String>

    public init(endpoint: URL, key: PushPairingKey, muted: Set<String> = []) {
        self.endpoint = endpoint
        self.key = key
        self.muted = muted
    }

    static let header = "purrdr-push 1"

    public var contents: Data {
        // session 值會被寫成一行;含換行或 `=` 以外的控制字元的值不寫(herdr 的 session 值是 id 或路徑)。
        let mutedLines = muted.filter(Self.isSafeLine).sorted().map { "muted=\($0)" }
        let lines = [Self.header, "endpoint=\(endpoint.absoluteString)", "key=\(key.hex)"] + mutedLines
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// 讀回主機上的配對檔;不是這個格式回 `nil`。
    public init?(contents: Data) {
        let lines = String(decoding: contents, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first == Self.header else { return nil }
        var endpoint: URL?
        var key: PushPairingKey?
        var muted: Set<String> = []
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: separator)...])
            switch line[..<separator] {
            case "endpoint": endpoint = URL(string: value)
            case "key": key = PushPairingKey(hex: value)
            case "muted": muted.insert(value)
            default: continue
            }
        }
        guard let endpoint, let key else { return nil }
        self.init(endpoint: endpoint, key: key, muted: muted)
    }

    static func isSafeLine(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
