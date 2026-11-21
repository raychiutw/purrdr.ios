import Crypto
import Foundation
import NIOSSH

/// 用什麼登入主機(GLOSSARY「連線方式」;ADR-0003)。
///
/// - `none`:Tailscale SSH,由 tailnet 身分放行。
/// - `password`:OpenSSH 的密碼登入。
/// - `privateKey`:OpenSSH 的公鑰登入(匯入的 ed25519／ECDSA,或這支裝置 Secure Enclave 裡的金鑰)。
public enum SSHUserCredential: Sendable {
    case none
    case password(String)
    case privateKey(SSHPrivateKey)
}

/// 撥號時才取得憑證(行為規格 §7.1「Lazy:建立 client 不讀 Keychain」)。丟出的錯誤會原樣讓這次連線失敗。
public typealias SSHCredentialProvider = @Sendable () async throws -> SSHUserCredential

/// 可以拿來登入的私鑰。支援 ed25519、ECDSA(P-256／P-384／P-521)與 Secure Enclave P-256;
/// swift-nio-ssh 不支援 RSA(ADR-0003)。
public struct SSHPrivateKey: Sendable {
    package let key: NIOSSHPrivateKey

    init(key: NIOSSHPrivateKey) {
        self.key = key
    }

    /// 軟體 P-256 金鑰(測試與 UI 測試裡代替 Secure Enclave)。
    public init(p256 key: P256.Signing.PrivateKey) {
        self.key = NIOSSHPrivateKey(p256Key: key)
    }

    #if canImport(Darwin)
    /// Secure Enclave 裡的 P-256 金鑰:私鑰不離開 Secure Enclave,簽章在 Secure Enclave 內完成。
    public init(secureEnclave key: SecureEnclave.P256.Signing.PrivateKey) {
        self.key = NIOSSHPrivateKey(secureEnclaveP256Key: key)
    }
    #endif

    /// 對應的公鑰(不含註解)。
    public var publicKey: SSHPublicKey {
        SSHPublicKey(openSSH: String(openSSHPublicKey: key.publicKey))
    }
}

/// OpenSSH 一行格式的公鑰(`ecdsa-sha2-nistp256 AAAA… 註解`)。
public struct SSHPublicKey: Sendable, Hashable {
    /// `<演算法> <base64>`,加註解時再接 ` <註解>`。
    public let openSSH: String

    public init(openSSH: String) {
        self.openSSH = openSSH
    }

    /// 加上註解(放進 `authorized_keys` 後讓人認得是哪支裝置)。註解裡的換行換成空白。
    public func withComment(_ comment: String) -> SSHPublicKey {
        let fields = openSSH.split(separator: " ").prefix(2).joined(separator: " ")
        let cleaned = comment.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return SSHPublicKey(openSSH: cleaned.isEmpty ? fields : fields + " " + cleaned)
    }

    /// 註解只留 ASCII 字元(沒有可留的就用 `purrdr`)。給使用者貼到 Windows 主控台的指令用:CP950 主控台會把非 ASCII 讀壞。
    public var asciiOnly: SSHPublicKey {
        let fields = openSSH.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count > 2 else { return self }
        let comment = fields.dropFirst(2).joined(separator: " ")
        guard !comment.unicodeScalars.allSatisfy(\.isASCII) else { return self }
        let kept = String(String.UnicodeScalarView(comment.unicodeScalars.filter(\.isASCII))).trimmingCharacters(in: .whitespaces)
        return SSHPublicKey(openSSH: fields.prefix(2).joined(separator: " ") + " " + (kept.isEmpty ? "purrdr" : kept))
    }

    /// 演算法名稱，例如 `ecdsa-sha2-nistp256`。
    public var algorithm: String { String(openSSH.split(separator: " ").first ?? "") }

    /// 與 `ssh-keygen -lf` 相同的 SHA-256 指紋。
    public var fingerprint: HostKeyFingerprint {
        // 公鑰一定是 `<演算法> <base64>`,由 swift-nio-ssh 產生或已驗證過。
        (try? HostKeyFingerprint(openSSHPublicKey: openSSH)) ?? HostKeyFingerprint(wireEncodedKey: Data())
    }
}
