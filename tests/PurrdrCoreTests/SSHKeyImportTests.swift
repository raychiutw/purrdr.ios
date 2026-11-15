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

        let imported = try SSHPrivateKey(openSSH: key.privateText, passphrase: nil)

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }

    @Test("沒有 passphrase 的 ECDSA 金鑰(P-256／P-384／P-521)", arguments: [256, 384, 521])
    func importsUnencryptedECDSA(bits: Int) throws {
        let key = try SSHKeygen.generate(type: "ecdsa", bits: bits)
        defer { key.remove() }

        let imported = try SSHPrivateKey(openSSH: key.privateText, passphrase: nil)

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }

    @Test("ssh-keygen 預設加密(bcrypt + aes256-ctr)的金鑰：帶對的 passphrase 可以匯入", arguments: ["ed25519", "ecdsa"])
    func importsEncryptedKey(type: String) throws {
        let key = try SSHKeygen.generate(type: type, passphrase: "correct horse")
        defer { key.remove() }

        let imported = try SSHPrivateKey(openSSH: key.privateText, passphrase: "correct horse")

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }

    @Test("其他 ssh-keygen 可選的加密方式", arguments: ["aes128-ctr", "aes256-gcm@openssh.com"])
    func importsOtherCiphers(cipher: String) throws {
        let key = try SSHKeygen.generate(type: "ed25519", passphrase: "pass phrase", cipher: cipher)
        defer { key.remove() }

        let imported = try SSHPrivateKey(openSSH: key.privateText, passphrase: "pass phrase")

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }

    @Test("passphrase 錯：說 passphrase 錯，不是格式錯誤", arguments: ["aes256-ctr", "aes256-gcm@openssh.com"])
    func wrongPassphrase(cipher: String) throws {
        let key = try SSHKeygen.generate(type: "ed25519", passphrase: "right", cipher: cipher)
        defer { key.remove() }

        #expect(throws: SSHKeyImportError.wrongPassphrase) {
            try SSHPrivateKey(openSSH: key.privateText, passphrase: "wrong")
        }
    }

    @Test("有 passphrase 的金鑰沒填 passphrase:要求填寫", arguments: [nil, ""] as [String?])
    func passphraseRequired(passphrase: String?) throws {
        let key = try SSHKeygen.generate(type: "ecdsa", passphrase: "secret")
        defer { key.remove() }

        #expect(throws: SSHKeyImportError.passphraseRequired) {
            try SSHPrivateKey(openSSH: key.privateText, passphrase: passphrase)
        }
    }

    @Test("RSA 金鑰(OpenSSH 格式或舊的 PEM 格式):說明不支援 RSA,有 passphrase 也不用先填")
    func rsaIsNotSupported() throws {
        let openSSH = try SSHKeygen.generate(type: "rsa", bits: 2048, passphrase: "secret")
        defer { openSSH.remove() }
        let pem = try SSHKeygen.generate(type: "rsa", bits: 2048, format: "PEM")
        defer { pem.remove() }

        #expect(throws: SSHKeyImportError.rsaNotSupported) { try SSHPrivateKey(openSSH: openSSH.privateText, passphrase: nil) }
        #expect(throws: SSHKeyImportError.rsaNotSupported) { try SSHPrivateKey(openSSH: pem.privateText, passphrase: nil) }
    }

    @Test("貼上公鑰或其他東西：說明需要私鑰")
    func notAPrivateKey() throws {
        let key = try SSHKeygen.generate(type: "ed25519")
        defer { key.remove() }

        #expect(throws: SSHKeyImportError.publicKeyInsteadOfPrivate) {
            try SSHPrivateKey(openSSH: key.publicKeyWithoutComment + " me@laptop", passphrase: nil)
        }
        #expect(throws: SSHKeyImportError.unsupportedFormat) { try SSHPrivateKey(openSSH: "hello", passphrase: nil) }
        let truncated = String(key.privateText.dropLast(80))
        #expect(throws: SSHKeyImportError.malformed) { try SSHPrivateKey(openSSH: truncated, passphrase: nil) }
    }

    @Test("貼上時多出的縮排、CRLF 換行都容忍")
    func toleratesPastedWhitespace() throws {
        let key = try SSHKeygen.generate(type: "ed25519")
        defer { key.remove() }
        let pasted = "\n  " + key.privateText.replacingOccurrences(of: "\n", with: "\r\n  ") + "\n\n"

        let imported = try SSHPrivateKey(openSSH: pasted, passphrase: nil)

        #expect(imported.publicKey.openSSH == key.publicKeyWithoutComment)
    }
}

#endif
