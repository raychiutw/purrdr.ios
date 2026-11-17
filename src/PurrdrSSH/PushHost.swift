import Foundation
import PurrdrCore

/// 同意前讀到的主機狀態。
public struct PushHostInspection: Sendable, Equatable {
    /// 執行的主機使用者(同意畫面要說明以哪個使用者安裝)。
    public var user: String
    /// 這支裝置在這台主機上已有推播配對。
    public var isPaired: Bool
    /// herdr 已安裝主機外掛(不論是誰裝的)。
    public var pluginInstalled: Bool

    public init(user: String, isPaired: Bool, pluginInstalled: Bool) {
        self.user = user
        self.isPaired = isPaired
        self.pluginInstalled = pluginInstalled
    }
}

public enum PushHostError: Error, Equatable {
    /// `herdr plugin install` 失敗(主機沒有 git、連不上 GitHub、herdr 太舊…);附 herdr 的訊息。主機已回到配對前的樣子。
    case pluginInstallFailed(String)
    /// `herdr plugin uninstall` 失敗;配對已移除，外掛還在(沒有配對時外掛什麼都不送)。
    case pluginUninstallFailed(String)
    /// 問 herdr 有沒有安裝外掛失敗(多半是 herdr 伺服器沒在跑)。
    case pluginListFailed(String)
    /// 主機上找不到這支裝置的配對檔。
    case notPaired
}

/// 推播的主機端(ADR-0004、行為規格 F14、§9.6):主機外掛與推播配對。
///
/// - **推播配對**:每支裝置一個 `~/.purrdr/push-<裝置 id>/pairing`(`PushPairingFile`),經 `ReversibleHostWrite` 寫入、
///   關閉時整個資料夾移除。一台主機可以配對多支裝置，各自一個資料夾。
/// - **主機外掛**:經 `herdr plugin install <來源> --yes` 安裝(herdr 官方的 plugin 機制)。只有 Purrdr 裝的才會由
///   Purrdr 移除：安裝前先寫 `~/.purrdr/push-plugin/` 當紀錄;最後一支裝置關閉推播時，有這個紀錄才 `herdr plugin uninstall`。
///   使用者自己裝的外掛不動。
/// - 安裝外掛失敗時把剛寫的配對與紀錄移除，主機回到配對前的樣子。
///
/// herdr 自己為 plugin 建的 config／state 資料夾在移除後仍會保留(herdr 文件:「Config and state are preserved」),
/// 外掛不在裡面放任何東西。Windows 主機(PowerShell 方言)還沒做，只有 POSIX。
public struct PushHost: Sendable {
    /// `host-plugin/herdr-plugin.toml` 的 id。
    public static let pluginID = "purrdr.push"
    /// 「外掛是 Purrdr 裝的」的紀錄。裝置 id 不能是 `plugin`,才不會撞名。
    static let pluginFeature = HostWriteFeature(id: "push-plugin", userFiles: [])

    let channel: any HostChannel
    let herdr: HerdrInstallation
    let pluginSource: String
    let pairingFeature: HostWriteFeature
    /// 指令期限的計時(測試注入)。
    let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - deviceID: 這支裝置的 id(`isValidDeviceID`),決定配對資料夾。
    ///   - pluginSource: `herdr plugin install` 的 GitHub 來源(`owner/repo[/subdir]`)。
    public init(
        channel: any HostChannel, herdr: HerdrInstallation, deviceID: String, pluginSource: String,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        precondition(Self.isValidDeviceID(deviceID), "裝置 id 會拼進主機路徑")
        self.channel = channel
        self.sleep = sleep
        self.herdr = herdr
        self.pluginSource = pluginSource
        pairingFeature = HostWriteFeature(id: "push-\(deviceID)", userFiles: [])
    }

    /// 裝置 id 會拼進主機路徑：只接受 1～64 個小寫英數與 `-`,且不能是 `plugin`。
    public static func isValidDeviceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id != "plugin"
            && id.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
    }

    var pairingPath: HostPath { pairingFeature.ownFile("pairing") }

    /// 同意前的檢查：以哪個使用者、這支裝置是否已配對、外掛是否已安裝。
    public func inspect() async throws -> PushHostInspection {
        let inspection = try await ReversibleHostWrite(channel: channel, feature: pairingFeature).inspect(also: [pairingPath])
        let isPaired = inspection.read[pairingPath]?.contents != nil
        return PushHostInspection(user: inspection.read.user, isPaired: isPaired, pluginInstalled: try await pluginInstalled())
    }

    /// 寫入這支裝置的推播配對，外掛還沒安裝就安裝。
    public func pair(_ file: PushPairingFile) async throws {
        let pairing = ReversibleHostWrite(channel: channel, feature: pairingFeature)
        try await pairing.install { _ in HostWritePlan(userFiles: [:], ownFiles: ["pairing": .init(file.contents)]) }
        guard try await !pluginInstalled() else { return }
        let marker = ReversibleHostWrite(channel: channel, feature: Self.pluginFeature)
        try await marker.install { _ in HostWritePlan(userFiles: [:], ownFiles: ["source": .init(Data((pluginSource + "\n").utf8))]) }
        let result = try await run(HerdrCommand.pluginInstall(source: pluginSource, herdr: herdr), deadline: HostCommandDeadline.download)
        guard result.exitCode == 0 else {
            try await marker.restore { _, current, _ in current }
            try await pairing.restore { _, current, _ in current }
            throw PushHostError.pluginInstallFailed(result.message)
        }
    }

    /// 移除這支裝置的推播配對;沒有其他裝置的配對、且外掛是 Purrdr 裝的，就一併移除外掛。
    public func unpair() async throws {
        try await ReversibleHostWrite(channel: channel, feature: pairingFeature).restore { _, current, _ in current }
        guard try await otherPairings().isEmpty else { return }
        let marker = ReversibleHostWrite(channel: channel, feature: Self.pluginFeature)
        guard try await marker.inspect().isInstalled else { return }
        if try await pluginInstalled() {
            let result = try await run(HerdrCommand.pluginUninstall(id: Self.pluginID, herdr: herdr))
            guard result.exitCode == 0 else { throw PushHostError.pluginUninstallFailed(result.message) }
        }
        try await marker.restore { _, current, _ in current }
    }

    /// 改寫這支裝置的靜音清單(聊天的 session 值),其餘內容不變。
    public func setMuted(_ muted: Set<String>) async throws {
        let files = HostFiles(channel: channel)
        let read = try await files.read([pairingPath])
        guard case .file(let data, let version)? = read[pairingPath], var file = PushPairingFile(contents: data) else {
            throw PushHostError.notPaired
        }
        file.muted = muted
        try await files.apply([.write(pairingPath, file.contents, expecting: .version(version))])
    }

    // MARK: - 主機指令

    func pluginInstalled() async throws -> Bool {
        let result = try await run(HerdrCommand.pluginList(id: Self.pluginID, herdr: herdr))
        guard result.exitCode == 0 else { throw PushHostError.pluginListFailed(result.message) }
        return result.stdout.contains(#""plugin_id":"\#(Self.pluginID)""#)
    }

    /// 列出 `~/.purrdr/push-*/pairing`(Windows 版是 `WindowsScripts.pushPairings`)。
    static let otherPairingsScript = #"cd "$HOME/.purrdr" 2>/dev/null && ls -1d push-*/pairing 2>/dev/null"#

    /// 其他裝置在這台主機上的配對(`push-<id>/pairing`,不含自己)。
    func otherPairings() async throws -> [String] {
        let result = try await run(HostFileScript.command(Self.otherPairingsScript, arguments: []))
        let own = "\(pairingFeature.id)/pairing"
        return result.stdout.split(separator: "\n").map(String.init).filter { $0.hasPrefix("push-") && $0 != own }
    }

    struct Result {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        /// 給使用者看的錯誤訊息：herdr 的 stderr(沒有就用 stdout)。
        var message: String {
            let text = stderr.isEmpty ? stdout : stderr
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 執行一般指令，在期限內收齊輸出。非零 exit 是結果不是例外(行為規格 §3.2)。
    func run(_ command: String, deadline: Duration = HostCommandDeadline.standard) async throws -> Result {
        let result = try await channel.collect(command, deadline: deadline, sleep: sleep)
        return Result(stdout: result.stdoutText, stderr: String(decoding: result.stderr, as: UTF8.self), exitCode: result.exitCode)
    }
}
