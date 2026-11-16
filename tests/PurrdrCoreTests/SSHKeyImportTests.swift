#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 匯入 OpenSSH 格式的私鑰。金鑰每次用本機的 `ssh-keygen` 臨時產生在暫存資料夾，測完刪除;
/// 解出來的公鑰要與 `ssh-keygen -y` 從同一個檔案算出的完全相同。
@Suite("匯入金鑰")
struct SSHKeyImportTests {
    @Test("沒有 passphrase 的 ed25519 金鑰：公鑰與 ssh-keygen -y 相同")
    func importsUnencryptedEd25519() throws {
        let key = try SSHKeygen.generate(type: "ed25519")
        defer { key.remove() }

        let imported = try SSHPrivateKey(openSSH: key.privateText)

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }

    @Test("沒有 passphrase 的 ECDSA 金鑰(P-256／P-384／P-521)", arguments: [256, 384, 521])
    func importsUnencryptedECDSA(bits: Int) throws {
        let key = try SSHKeygen.generate(type: "ecdsa", bits: bits)
        defer { key.remove() }

        let imported = try SSHPrivateKey(openSSH: key.privateText)

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }

    /// 出口合規(只用系統加密):OpenSSH 私鑰只要有 passphrase,私密區段就以 bcrypt KDF 推導金鑰加密
    /// (`ssh-keygen` 只產生 bcrypt;cipher 不是 none 時 kdf 一定是 bcrypt),不論 cipher 是 aes-ctr 或 aes-gcm。
    /// 不實作 bcrypt,所以一律回明確錯誤，請使用者先移除 passphrase。
    @Test(
        "有 passphrase 的金鑰(bcrypt + aes-ctr／aes-gcm):回 passphrase 保護錯誤，請先移除 passphrase",
        arguments: [
            ("ed25519", nil), ("ecdsa", nil), ("ed25519", "aes128-ctr"), ("ed25519", "aes256-gcm@openssh.com"),
        ] as [(String, String?)])
    func passphraseProtectedKeyIsRejected(type: String, cipher: String?) throws {
        let key = try SSHKeygen.generate(type: type, passphrase: "correct horse", cipher: cipher)
        defer { key.remove() }
        #expect(key.privateText.contains("BEGIN OPENSSH PRIVATE KEY"))

        #expect(throws: SSHKeyImportError.passphraseProtected) {
            try SSHPrivateKey(openSSH: key.privateText)
        }
    }

    @Test("RSA 金鑰(OpenSSH 格式或舊的 PEM 格式):說明不支援 RSA,有 passphrase 也不用先填")
    func rsaIsNotSupported() throws {
        let openSSH = try SSHKeygen.generate(type: "rsa", bits: 2048, passphrase: "secret")
        defer { openSSH.remove() }
        let pem = try SSHKeygen.generate(type: "rsa", bits: 2048, format: "PEM")
        defer { pem.remove() }

        #expect(throws: SSHKeyImportError.rsaNotSupported) { try SSHPrivateKey(openSSH: openSSH.privateText) }
        #expect(throws: SSHKeyImportError.rsaNotSupported) { try SSHPrivateKey(openSSH: pem.privateText) }
    }

    @Test("貼上公鑰或其他東西：說明需要私鑰")
    func notAPrivateKey() throws {
        let key = try SSHKeygen.generate(type: "ed25519")
        defer { key.remove() }

        #expect(throws: SSHKeyImportError.publicKeyInsteadOfPrivate) {
            try SSHPrivateKey(openSSH: key.publicKeyWithoutComment + " me@laptop")
        }
        #expect(throws: SSHKeyImportError.unsupportedFormat) { try SSHPrivateKey(openSSH: "hello") }
        let truncated = String(key.privateText.dropLast(80))
        #expect(throws: SSHKeyImportError.malformed) { try SSHPrivateKey(openSSH: truncated) }
    }

    @Test("貼上時多出的縮排、CRLF 換行都容忍")
    func toleratesPastedWhitespace() throws {
        let key = try SSHKeygen.generate(type: "ed25519")
        defer { key.remove() }
        let pasted = "\n  " + key.privateText.replacingOccurrences(of: "\n", with: "\r\n  ") + "\n\n"

        let imported = try SSHPrivateKey(openSSH: pasted)

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }
}

#endif
