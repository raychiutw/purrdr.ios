import PurrdrCore
import Testing

@Suite("Host key 指紋")
struct HostKeyFingerprintTests {
    // 預期值是對同一把公鑰執行 `ssh-keygen -lf` 印出的結果(行為規格 §8.2)。
    @Test("ed25519 公鑰的指紋與 ssh-keygen -lf 相同")
    func ed25519MatchesSSHKeygen() throws {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHyHCZX04A3TF5ug5JRjXYZ2+Ku3wMdYmgn5Jsbu1bd7 test"
        let fingerprint = try HostKeyFingerprint(openSSHPublicKey: key)
        #expect(fingerprint.description == "SHA256:COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")
    }

    @Test("ECDSA P-256 公鑰的指紋與 ssh-keygen -lf 相同")
    func ecdsaMatchesSSHKeygen() throws {
        let key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGD6bqw5z6JsVt8fes3KJhryV0wKrkFshJdMVh6wEnhT8Or2Q5VSBZCn6k1EfhWFwFo1RkXil4w7XchQYYl1sw0="
        let fingerprint = try HostKeyFingerprint(openSSHPublicKey: key)
        #expect(fingerprint.description == "SHA256:d3UZ4WSMqwA9f7HNdFV7b3Dde7LFqimgoeahTmn0d0I")
    }

    @Test("存的指紋不含前綴與補位；讀回時容忍前綴與補位(舊資料)")
    func storedFormIgnoresPrefixAndPadding() throws {
        let fingerprint = try HostKeyFingerprint(openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHyHCZX04A3TF5ug5JRjXYZ2+Ku3wMdYmgn5Jsbu1bd7")
        #expect(fingerprint.stored == "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")
        #expect(HostKeyFingerprint(stored: "SHA256:COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww=") == fingerprint)
    }

    @Test("空指紋永遠不是 pin")
    func emptyIsNeverAPin() {
        #expect(HostKeyFingerprint(stored: "") == nil)
        #expect(HostKeyFingerprint(stored: "SHA256:") == nil)
    }
}
