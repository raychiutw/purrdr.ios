import _CryptoExtras
import Crypto
import Foundation

/// OpenSSH 私鑰檔裡私密區段的加密(`ssh-keygen` 預設 `bcrypt` + `aes256-ctr`)。
enum OpenSSHCipher {
    private enum Mode {
        case ctr
        case gcm
    }

    /// 解開私密區段。`tag` 是 AEAD 加密(gcm)附在區段之後的驗證碼。
    static func open(
        _ sealed: Data, tag: Data, cipher: String, kdf: String, kdfOptions: Data, passphrase: String?
    ) throws(SSHKeyImportError) -> Data {
        if cipher == "none" {
            guard kdf == "none" else { throw .malformed }
            return sealed
        }
        let (mode, keySize): (Mode, Int) = switch cipher {
        case "aes128-ctr": (.ctr, 16)
        case "aes192-ctr": (.ctr, 24)
        case "aes256-ctr": (.ctr, 32)
        case "aes128-gcm@openssh.com": (.gcm, 16)
        case "aes256-gcm@openssh.com": (.gcm, 32)
        default: throw .unsupportedCipher(cipher)
        }
        guard kdf == "bcrypt" else { throw .unsupportedCipher(cipher) }
        guard let passphrase, !passphrase.isEmpty else { throw .passphraseRequired }

        var options = SSHWireReader(kdfOptions)
        let salt = try options.bytes()
        let rounds = Int(try options.uint32())
        guard !salt.isEmpty, (1...1 << 20).contains(rounds) else { throw .malformed }
        let ivSize = mode == .ctr ? 16 : 12
        let derived = BcryptPBKDF.derive(passphrase: Data(passphrase.utf8), salt: salt, rounds: rounds, count: keySize + ivSize)
        let key = SymmetricKey(data: derived.prefix(keySize))
        let iv = derived.suffix(ivSize)

        do {
            switch mode {
            case .ctr:
                return try AES._CTR.decrypt(sealed, using: key, nonce: AES._CTR.Nonce(nonceBytes: iv))
            case .gcm:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: sealed, tag: tag.prefix(16))
                do {
                    return try AES.GCM.open(box, using: key)
                } catch {
                    // 驗證碼不符 = passphrase 錯(或檔案被改過)。
                    throw SSHKeyImportError.wrongPassphrase
                }
            }
        } catch let error as SSHKeyImportError {
            throw error
        } catch {
            throw .malformed
        }
    }
}
