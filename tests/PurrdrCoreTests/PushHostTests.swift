#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 推播的主機端(ADR-0004、ADR-0002):經 SSH 安裝主機外掛、寫入推播配對，關閉時移除外掛與設定。
///
/// 以 `LocalShellHost`(暫存家目錄、真的 `/bin/sh`)執行;`herdr` 換成家目錄 `bin/` 的假程式，
/// 它記錄收到的 `plugin` 指令，並以 `fake/installed` 代表「herdr 已安裝 purrdr.push」。
@Suite("推播(主機)")
struct PushHostTests {
    static let endpoint = URL(string: "https://backend.test/v1/push")!
    static let source = "raychiutw/purrdr.host/host-plugin"

    let host: LocalShellHost

    init() throws {
        host = try LocalShellHost.temporary()
        try FakeHerdrPluginCLI.install(on: host)
    }

    func push(device: String = "0123456789abcdef") -> PushHost {
        PushHost(channel: host, herdr: HerdrInstallation(), deviceID: device, pluginSource: Self.source)
    }

    func pairing(_ key: PushPairingKey = .generate(), muted: Set<String> = []) -> PushPairingFile {
        PushPairingFile(endpoint: Self.endpoint, key: key, muted: muted)
    }

    func snapshot() throws -> DirectorySnapshot { try FakeHerdrPluginCLI.snapshot(of: host) }

    var pluginInstalled: Bool { FakeHerdrPluginCLI.isPluginInstalled(on: host) }

    func herdrCalls() throws -> [String] { try FakeHerdrPluginCLI.calls(on: host) }

    @Test("在乾淨的主機上配對：以 herdr 安裝主機外掛，配對檔只有本人可讀")
    func pairingInstallsPluginAndWritesPairing() async throws {
        let file = pairing(muted: ["session-1"])

        try await push().pair(file)

        #expect(pluginInstalled)
        #expect(try herdrCalls().contains("plugin install raychiutw/purrdr.host/host-plugin --yes"))
        let url = host.url(".purrdr/push-0123456789abcdef/pairing")
        #expect(PushPairingFile(contents: try Data(contentsOf: url)) == file)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let inspection = try await push().inspect()
        #expect(inspection.isPaired)
        #expect(inspection.pluginInstalled)
        #expect(inspection.user == NSUserName())
    }

    @Test("關閉推播：移除外掛與配對，主機與配對前完全相同")
    func unpairRestoresHostExactly() async throws {
        try host.write(Data("keep me\n".utf8), to: "notes.txt")
        let before = try snapshot()

        try await push().pair(pairing())
        try await push().unpair()

        #expect(try snapshot() == before)
        #expect(!pluginInstalled)
        #expect(try herdrCalls().contains("plugin uninstall purrdr.push"))
        #expect(try await push().inspect().isPaired == false)
    }

    @Test("使用者自己裝的外掛：配對不重裝，關閉時也不移除")
    func pluginInstalledByUserIsLeftAlone() async throws {
        try host.write(Data(), to: "fake/installed")
        let before = try snapshot()

        try await push().pair(pairing())
        try await push().unpair()

        #expect(pluginInstalled)
        let calls = try herdrCalls()
        #expect(!calls.contains { $0.hasPrefix("plugin install") || $0.hasPrefix("plugin uninstall") })
        #expect(try snapshot() == before)
    }

    @Test("同一台主機配對兩支裝置：外掛留到最後一支關閉才移除")
    func pluginStaysUntilLastDeviceUnpairs() async throws {
        let before = try snapshot()
        let phone = push(device: "aaaaaaaaaaaaaaaa")
        let pad = push(device: "bbbbbbbbbbbbbbbb")
        try await phone.pair(pairing())
        try await pad.pair(pairing())
        #expect(try herdrCalls().filter { $0.hasPrefix("plugin install") }.count == 1)

        try await phone.unpair()
        #expect(pluginInstalled)
        #expect(try await pad.inspect().isPaired)

        try await pad.unpair()
        #expect(!pluginInstalled)
        #expect(try snapshot() == before)
    }

    @Test("外掛安裝失敗：丟出 herdr 的訊息，主機回到配對前的樣子")
    func failedPluginInstallRollsBack() async throws {
        try host.write(Data(), to: "fake/install-fails")
        let before = try snapshot()

        await #expect(throws: PushHostError.pluginInstallFailed("git clone failed")) {
            try await push().pair(pairing())
        }

        #expect(try snapshot() == before)
    }

    @Test("靜音：只改配對檔的靜音清單，密鑰不變")
    func setMutedRewritesOnlyMutedList() async throws {
        let key = PushPairingKey.generate()
        try await push().pair(pairing(key, muted: ["old"]))

        try await push().setMuted(["session-1", "session-2"])

        let url = host.url(".purrdr/push-0123456789abcdef/pairing")
        let file = try #require(PushPairingFile(contents: try Data(contentsOf: url)))
        #expect(file.key == key)
        #expect(file.endpoint == Self.endpoint)
        #expect(file.muted == ["session-1", "session-2"])
    }

    @Test("裝置 id 只能是小寫英數與 -(會拼進路徑)")
    func deviceIDIsValidated() {
        #expect(PushHost.isValidDeviceID("0123456789abcdef"))
        #expect(!PushHost.isValidDeviceID("../x"))
        #expect(!PushHost.isValidDeviceID(""))
        #expect(!PushHost.isValidDeviceID("plugin"))
    }
}

/// 推播配對密鑰與配對檔。
@Suite("推播配對")
struct PushPairingTests {
    @Test("雜湊是密鑰 32 bytes 的 SHA-256(與後台相同)")
    func hashIsSHA256OfKeyBytes() throws {
        // 已知值：32 個 0x00 bytes 的 SHA-256(`head -c 32 /dev/zero | shasum -a 256`)。
        let key = try #require(PushPairingKey(hex: String(repeating: "0", count: 64)))
        #expect(key.hash == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
    }

    @Test("每次產生的密鑰都不同，hex 是 64 位小寫")
    func generatedKeysAreRandom() {
        let first = PushPairingKey.generate()
        let second = PushPairingKey.generate()
        #expect(first != second)
        #expect(first.hex.count == 64)
        #expect(PushPairingKey(hex: first.hex) == first)
    }

    @Test("描述文字不含密鑰本身")
    func descriptionHidesKey() {
        let key = PushPairingKey.generate()
        #expect(!"\(key)".contains(key.hex))
    }

    @Test("配對檔讀寫往返;含換行的靜音值不寫入")
    func pairingFileRoundTrip() throws {
        let file = PushPairingFile(endpoint: URL(string: "https://b.test/v1/push")!, key: .generate(), muted: ["a", "b\nkey=evil"])
        let text = String(decoding: file.contents, as: UTF8.self)
        #expect(!text.contains("evil"))
        #expect(PushPairingFile(contents: file.contents)?.muted == ["a"])
    }
}
#endif
