import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 推播外掛安裝的共同行為(spec #261):每個實作都要一樣，畫面 model 換實作不必改。
@Suite("推播外掛安裝：各實作的共同行為")
struct PushPluginInstallerContractTests {
    static let endpoint = URL(string: "https://backend.test/v1/push")!

    static var kinds: [InstallerKind] {
        #if os(macOS)
        [.fake, .ssh]
        #else
        [.fake]
        #endif
    }

    func pairing(muted: Set<String> = []) -> PushPairingFile {
        PushPairingFile(endpoint: Self.endpoint, key: .generate(), muted: muted)
    }

    @Test("乾淨的主機：沒有外掛、沒有配對", arguments: kinds)
    func cleanHost(kind: InstallerKind) async throws {
        let host = try kind.makeHost()

        let status = try await host.installer("aaaaaaaaaaaaaaaa").status()

        #expect(!status.isPaired)
        #expect(!status.pluginInstalled)
        #expect(status.otherPairedDevices == 0)
        #expect(!status.user.isEmpty)
    }

    @Test("安裝：這支裝置已配對、外掛已安裝", arguments: kinds)
    func installPairsAndInstallsPlugin(kind: InstallerKind) async throws {
        let host = try kind.makeHost()
        let installer = host.installer("aaaaaaaaaaaaaaaa")

        try await installer.install(pairing())

        let status = try await installer.status()
        #expect(status.isPaired)
        #expect(status.pluginInstalled)
    }

    @Test("兩支裝置：各自看到另一支，移除一支外掛還在，最後一支移除外掛才移除", arguments: kinds)
    func multipleDevicesShareThePlugin(kind: InstallerKind) async throws {
        let host = try kind.makeHost()
        let phone = host.installer("aaaaaaaaaaaaaaaa")
        let pad = host.installer("bbbbbbbbbbbbbbbb")
        try await phone.install(pairing())
        try await pad.install(pairing())

        #expect(try await phone.status().otherPairedDevices == 1)

        try await phone.remove()
        let padStatus = try await pad.status()
        #expect(padStatus.isPaired)
        #expect(padStatus.pluginInstalled)
        #expect(padStatus.otherPairedDevices == 0)
        #expect(try await phone.status().isPaired == false)

        try await pad.remove()
        #expect(try await pad.status().pluginInstalled == false)
    }

    @Test("使用者自己裝的外掛：移除配對時不移除外掛", arguments: kinds)
    func pluginInstalledOutsidePurrdrStays(kind: InstallerKind) async throws {
        let host = try kind.makeHost()
        try host.installPluginOutsidePurrdr()
        let installer = host.installer("aaaaaaaaaaaaaaaa")

        try await installer.install(pairing())
        try await installer.remove()

        let status = try await installer.status()
        #expect(status.pluginInstalled)
        #expect(!status.isPaired)
    }

    @Test("安裝外掛失敗：丟出 herdr 的訊息，主機回到安裝前", arguments: kinds)
    func failedInstallRollsBack(kind: InstallerKind) async throws {
        let host = try kind.makeHost()
        try host.failPluginInstall("git clone failed")
        let installer = host.installer("aaaaaaaaaaaaaaaa")

        await #expect(throws: PushPluginError.pluginInstallFailed("git clone failed")) {
            try await installer.install(pairing())
        }

        let status = try await installer.status()
        #expect(!status.isPaired)
        #expect(!status.pluginInstalled)
    }

    @Test("沒有配對時改靜音清單：notPaired", arguments: kinds)
    func updatingMutedWithoutPairingFails(kind: InstallerKind) async throws {
        let host = try kind.makeHost()

        await #expect(throws: PushPluginError.notPaired) {
            try await host.installer("aaaaaaaaaaaaaaaa").updateMuted(["session-1"])
        }
    }

    @Test("改靜音清單後仍是已配對", arguments: kinds)
    func updatingMutedKeepsPairing(kind: InstallerKind) async throws {
        let host = try kind.makeHost()
        let installer = host.installer("aaaaaaaaaaaaaaaa")
        try await installer.install(pairing(muted: ["old"]))

        try await installer.updateMuted(["session-1"])

        #expect(try await installer.status().isPaired)
    }
}

/// 被測的實作。
enum InstallerKind: String, CustomStringConvertible, Sendable {
    case fake
    case ssh

    var description: String { rawValue }

    func makeHost() throws -> any PushPluginTestHost {
        switch self {
        case .fake:
            return FakePushPluginHost()
        case .ssh:
            #if os(macOS)
            return try SSHPushPluginTestHost()
            #else
            fatalError("SSH 實作的測試主機只在 macOS")
            #endif
        }
    }
}

/// 測試對一台主機的操作：取某支裝置的安裝介面、安排失敗、模擬使用者自己裝的外掛。
protocol PushPluginTestHost {
    func installer(_ deviceID: String) -> any PushPluginInstalling
    func failPluginInstall(_ message: String) throws
    func installPluginOutsidePurrdr() throws
}

extension FakePushPluginHost: PushPluginTestHost {
    func installer(_ deviceID: String) -> any PushPluginInstalling { installer(deviceID: deviceID) }

    func failPluginInstall(_ message: String) throws { setInstallFailure(message) }
}

#if os(macOS)
/// SSH 實作對 `LocalShellHost`(暫存家目錄、真的 `/bin/sh`)與假 herdr。假 herdr 的失敗訊息固定是「git clone failed」。
struct SSHPushPluginTestHost: PushPluginTestHost {
    let host: LocalShellHost

    init() throws {
        host = try LocalShellHost.temporary()
        try FakeHerdrPluginCLI.install(on: host)
    }

    func installer(_ deviceID: String) -> any PushPluginInstalling {
        SSHPushPluginInstaller(
            channel: host, herdr: HerdrInstallation(), deviceID: deviceID, pluginSource: "raychiutw/purrdr.host/host-plugin")
    }

    func failPluginInstall(_ message: String) throws {
        precondition(message == "git clone failed")
        try host.write(Data(), to: "fake/install-fails")
    }

    func installPluginOutsidePurrdr() throws { try host.write(Data(), to: "fake/installed") }
}
#endif
