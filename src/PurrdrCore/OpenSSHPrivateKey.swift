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
    /// 金鑰有 passphrase 保護。
    ///
    /// 出口合規(`docs/launch/checklist.md`):app 只用系統加密(CryptoKit、CommonCrypto、系統 TLS)。
    /// OpenSSH 私鑰的 passphrase 一律以 bcrypt KDF(Blowfish)推導金鑰，系統沒有提供，所以不解密;
    /// 畫面請使用者先在電腦上 `ssh-keygen -p -N "" -f <私鑰>` 移除 passphrase 再匯入。
    case passphraseProtected
    /// 內容損毀或不完整。
    case malformed
}

extension SSHPrivateKey {
    /// 解讀沒有 passphrase 的 OpenSSH 格式私鑰(`ssh-keygen` 預設產生的格式)。
    ///
    /// 支援 ed25519 與 ECDSA(nistp256／384／521)。有 passphrase 的金鑰丟 `.passphraseProtected`
    /// (只用系統加密，見 `SSHKeyImportError.passphraseProtected`)。
    public init(openSSH text: String) throws(SSHKeyImportError) {
        let body = try OpenSSHPrivateKeyFile.body(of: text)
        self = try OpenSSHPrivateKeyFile.decode(body)
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

    static func decode(_ body: Data) throws(SSHKeyImportError) -> SSHPrivateKey {
        var reader = SSHWireReader(body)
        let cipher = try reader.string()
        let kdf = try reader.string()
        _ = try reader.bytes()  // KDF 參數
        guard try reader.uint32() == 1 else { throw .malformed }
        let publicBlob = try reader.bytes()
        try rejectUnsupportedType(of: publicBlob)
        // OpenSSH 規定：cipher 不是 none 時 kdf 一定是 bcrypt(= 有 passphrase);反之 kdf 是 none 時 cipher 也要是 none。
        guard cipher == "none" else { throw .passphraseProtected }
        guard kdf == "none" else { throw .malformed }
        return try privateKey(in: try reader.bytes())
    }

    /// 先看公鑰的種類：不支援的種類(例如有 passphrase 的 RSA)先說明不支援，不必先處理 passphrase。
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
        // 兩個相同的檢查值(加密時用來驗 passphrase;未加密時不同代表檔案損毀)。
        guard try reader.uint32() == reader.uint32() else { throw .malformed }
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
