import Crypto
import Foundation

/// 主機 host key 的指紋：公鑰 SSH wire 編碼的 SHA-256,不補等號的標準 base64(行為規格 §8.2)。
///
/// 與 `ssh-keygen -lf` 印出的 `SHA256:` 之後完全相同。儲存時不含前綴(`stored`),顯示時加上 `SHA256:`。
public struct HostKeyFingerprint: Sendable, Hashable, CustomStringConvertible {
    /// 使用者在那台電腦上自己比對指紋的指令(OpenSSH 預設的 ed25519 host key;畫面給拷貝鈕)。
    public static let compareCommand = "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"

    /// 依主機作業系統的比對指令:Windows 的 OpenSSH host key 在 `C:\ProgramData\ssh`。純 ASCII(CP950 主控台會把非 ASCII 讀壞)。
    public static func compareCommand(on system: HostOperatingSystem?) -> String {
        system == .windows
            ? #"ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub"#
            : compareCommand
    }

    /// 不含 `SHA256:` 前綴、不補等號的 base64。
    public let stored: String

    /// 從 OpenSSH 公鑰字串(`ssh-ed25519 AAAA… 註解`)計算。
    public init(openSSHPublicKey: String) throws {
        let fields = openSSHPublicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let wire = Data(base64Encoded: String(fields[1])), !wire.isEmpty else {
            throw HostKeyFingerprintError.malformedPublicKey
        }
        self.init(wireEncodedKey: wire)
    }

    /// 從公鑰的 SSH wire 編碼計算。
    init(wireEncodedKey: Data) {
        stored = Self.unpadded(Data(SHA256.hash(data: wireEncodedKey)).base64EncodedString())
    }

    /// 讀回儲存的指紋。容忍 `SHA256:` 前綴與補位(舊資料);空的指紋永遠不是 pin,回傳 `nil`。
    public init?(stored: String) {
        var value = Substring(stored)
        if value.hasPrefix("SHA256:") { value = value.dropFirst("SHA256:".count) }
        let unpadded = Self.unpadded(String(value))
        guard !unpadded.isEmpty else { return nil }
        self.stored = unpadded
    }

    public var description: String { "SHA256:" + stored }

    private static func unpadded(_ base64: String) -> String {
        String(base64.reversed().drop(while: { $0 == "=" }).reversed())
    }
}

extension HostKeyFingerprint: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let fingerprint = HostKeyFingerprint(stored: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "空的指紋不是 pin"))
        }
        self = fingerprint
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}

public enum HostKeyFingerprintError: Error, Equatable {
    /// 不是 `<演算法> <base64>` 形式的 OpenSSH 公鑰。
    case malformedPublicKey
}
