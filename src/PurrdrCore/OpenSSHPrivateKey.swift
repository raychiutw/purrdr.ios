import Crypto
import Foundation
import NIOSSH

/// 匯入私鑰失敗的原因。畫面依情況給說明;RSA 另外提供「改用這支裝置的金鑰」。
public enum SSHKeyImportError: Error, Equatable, Sendable {
    /// RSA 金鑰：swift-nio-ssh 不支援(ADR-0003)。
    case rsaNotSupported
    /// 其他不支援的金鑰種類(DSA、FIDO 安全金鑰 `sk-*` 等),附 OpenSSH 的種類名稱。
    case unsupportedKeyType(String)
    /// 不是 OpenSSH 格式(`BEGIN OPENSSH PRIVATE KEY`)的私鑰，例如 PEM、PKCS#8、PuTTY。
    case unsupportedFormat
    /// 看起來是公鑰，不是私鑰。
    case publicKeyInsteadOfPrivate
    /// 金鑰有 passphrase,但沒有提供。
    case passphraseRequired
    /// passphrase 不對。
    case wrongPassphrase
    /// 用不支援的加密方式保護(附 OpenSSH 的名稱)。
    case unsupportedCipher(String)
    /// 內容損毀或不完整。
    case malformed
}

extension SSHPrivateKey {
    /// 解讀 OpenSSH 格式的私鑰(`ssh-keygen` 預設產生的格式),可帶 passphrase。
    ///
    /// 支援 ed25519 與 ECDSA(nistp256／384／521);加密支援 `ssh-keygen` 預設的 bcrypt + aes256-ctr,
    /// 以及 aes128／192-ctr、aes128／256-gcm@openssh.com。
    public init(openSSH text: String, passphrase: String?) throws(SSHKeyImportError) {
        let body = try OpenSSHPrivateKeyFile.body(of: text)
        self = try OpenSSHPrivateKeyFile.decode(body, passphrase: passphrase)
    }
}

enum OpenSSHPrivateKeyFile {
    static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let end = "-----END OPENSSH PRIVATE KEY-----"
    static let magic = Data("openssh-key-v1\0".utf8)

    /// 取出 base64 內容並解碼。貼上時多出的空白、換行、`\r` 都容忍。
    static func body(of text: String) throws(SSHKeyImportError) -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.range(of: begin) else {
            if trimmed.contains("BEGIN RSA PRIVATE KEY") { throw .rsaNotSupported }
            if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") || trimmed.contains("BEGIN SSH2 PUBLIC KEY") {
                throw .publicKeyInsteadOfPrivate
            }
            throw .unsupportedFormat
        }
        guard let finish = trimmed.range(of: end, range: start.upperBound..<trimmed.endIndex) else { throw .malformed }
        let base64 = trimmed[start.upperBound..<finish.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)), data.starts(with: magic) else { throw .malformed }
        return data.dropFirst(magic.count)
    }

    static func decode(_ body: Data, passphrase: String?) throws(SSHKeyImportError) -> SSHPrivateKey {
        var reader = SSHWireReader(body)
        let cipher = try reader.string()
        let kdf = try reader.string()
        let kdfOptions = try reader.bytes()
        guard try reader.uint32() == 1 else { throw .malformed }
        let publicBlob = try reader.bytes()
        try rejectUnsupportedType(of: publicBlob)
        let sealed = try reader.bytes()
        let tag = reader.remaining
        let section = try OpenSSHCipher.open(
            sealed, tag: tag, cipher: cipher, kdf: kdf, kdfOptions: kdfOptions, passphrase: passphrase)
        return try privateKey(in: section)
    }

    /// 先看公鑰的種類：不支援的種類不需要 passphrase 就能說明。
    private static func rejectUnsupportedType(of publicBlob: Data) throws(SSHKeyImportError) {
        var reader = SSHWireReader(publicBlob)
        let type = try reader.string()
        switch type {
        case "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": return
        case "ssh-rsa": throw .rsaNotSupported
        default: throw .unsupportedKeyType(type)
        }
    }

    private static func privateKey(in section: Data) throws(SSHKeyImportError) -> SSHPrivateKey {
        var reader = SSHWireReader(section)
        // 兩個相同的檢查值：passphrase 錯時解出來的是亂碼，兩者幾乎不可能相同。
        guard try reader.uint32() == reader.uint32() else { throw .wrongPassphrase }
        let type = try reader.string()
        do {
            switch type {
            case "ssh-ed25519":
                _ = try reader.bytes()
                let secret = try reader.bytes()
                guard secret.count == 64 else { throw SSHKeyImportError.malformed }
                return SSHPrivateKey(key: NIOSSHPrivateKey(ed25519Key: try .init(rawRepresentation: secret.prefix(32))))
            case "ecdsa-sha2-nistp256":
                _ = try reader.string()
                _ = try reader.bytes()
                return SSHPrivateKey(key: NIOSSHPrivateKey(p256Key: try .init(rawRepresentation: scalar(try reader.bytes(), size: 32))))
            case "ecdsa-sha2-nistp384":
                _ = try reader.string()
                _ = try reader.bytes()
                return SSHPrivateKey(key: NIOSSHPrivateKey(p384Key: try .init(rawRepresentation: scalar(try reader.bytes(), size: 48))))
            case "ecdsa-sha2-nistp521":
                _ = try reader.string()
                _ = try reader.bytes()
                return SSHPrivateKey(key: NIOSSHPrivateKey(p521Key: try .init(rawRepresentation: scalar(try reader.bytes(), size: 66))))
            case "ssh-rsa":
                throw SSHKeyImportError.rsaNotSupported
            default:
                throw SSHKeyImportError.unsupportedKeyType(type)
            }
        } catch let error as SSHKeyImportError {
            throw error
        } catch {
            throw .malformed
        }
    }

    /// mpint(可能有開頭的 0,也可能比曲線短)→ 固定長度的大端序 scalar。
    private static func scalar(_ mpint: Data, size: Int) throws(SSHKeyImportError) -> Data {
        let digits = mpint.drop(while: { $0 == 0 })
        guard digits.count <= size else { throw .malformed }
        return Data(repeating: 0, count: size - digits.count) + digits
    }
}

/// SSH wire 格式(RFC 4251)的讀取器。
struct SSHWireReader {
    private var data: Data

    init(_ data: Data) {
        self.data = Data(data)
    }

    /// 還沒讀的部分。
    var remaining: Data { data }

    mutating func uint32() throws(SSHKeyImportError) -> UInt32 {
        guard data.count >= 4 else { throw .malformed }
        let value = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        data = data.dropFirst(4)
        return value
    }

    mutating func bytes() throws(SSHKeyImportError) -> Data {
        let count = Int(try uint32())
        guard data.count >= count else { throw .malformed }
        let value = Data(data.prefix(count))
        data = data.dropFirst(count)
        return value
    }

    mutating func string() throws(SSHKeyImportError) -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }
}
