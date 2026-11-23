import Foundation
import PurrdrCore

/// 推播外掛安裝的 SSH 實作(ADR-0004、行為規格 F14、§9.6):主機外掛與推播配對。
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
public struct SSHPushPluginInstaller: PushPluginInstalling {
    /// 主機外掛(raychiutw/purrdr.host 的 `host-plugin/herdr-plugin.toml`)的 id。
    public static let pluginID = "purrdr.push"
    /// 「外掛是 Purrdr 裝的」的紀錄。裝置 id 不能是 `plugin`,才不會撞名。
    static let pluginFeature = HostWriteFeature(id: "push-plugin", userFiles: [])

    let channel: any HostChannel
    let herdr: HerdrInstallation
    let pluginSource: String
    let pairingFeature: HostWriteFeature
    /// 指令期限的計時(測試注入)。
    let sleep: Sleep

    /// - Parameters:
    ///   - deviceID: 這支裝置的推播 id,決定配對資料夾。
    ///   - pluginSource: `herdr plugin install` 的 GitHub 來源(`owner/repo[/subdir]`)。
    public init(
        channel: any HostChannel, herdr: HerdrInstallation, deviceID: PushDeviceID, pluginSource: String,
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.channel = channel
        self.sleep = sleep
        self.herdr = herdr
        self.pluginSource = pluginSource
        pairingFeature = HostWriteFeature(id: "push-\(deviceID.rawValue)", userFiles: [])
    }

    var pairingPath: HostPath { pairingFeature.ownFile("pairing") }

    public func status() async throws -> PushPluginStatus {
        let inspection = try await ReversibleHostWrite(channel: channel, feature: pairingFeature).inspect(also: [pairingPath])
        let isPaired = inspection.read[pairingPath]?.contents != nil
        return PushPluginStatus(
            user: inspection.read.user, isPaired: isPaired, pluginInstalled: try await pluginInstalled(),
            otherPairedDevices: try await otherPairings().count)
    }

    public func install(_ file: PushPairingFile) async throws {
        let pairing = ReversibleHostWrite(channel: channel, feature: pairingFeature)
        try await pairing.install { _ in HostWritePlan(userFiles: [:], ownFiles: ["pairing": .init(file.contents)]) }
        guard try await !pluginInstalled() else { return }
        let marker = ReversibleHostWrite(channel: channel, feature: Self.pluginFeature)
        try await marker.install { _ in HostWritePlan(userFiles: [:], ownFiles: ["source": .init(Data((pluginSource + "\n").utf8))]) }
        let result = try await run(HerdrCommand.pluginInstall(source: pluginSource, herdr: herdr), deadline: HostCommandDeadline.download)
        guard result.exitCode == 0 else {
            try await marker.restore { _, current, _ in current }
            try await pairing.restore { _, current, _ in current }
            throw PushPluginError.pluginInstallFailed(result.message)
        }
    }

    public func remove() async throws {
        try await ReversibleHostWrite(channel: channel, feature: pairingFeature).restore { _, current, _ in current }
        guard try await otherPairings().isEmpty else { return }
        let marker = ReversibleHostWrite(channel: channel, feature: Self.pluginFeature)
        guard try await marker.inspect().isInstalled else { return }
        if try await pluginInstalled() {
            let result = try await run(HerdrCommand.pluginUninstall(id: Self.pluginID, herdr: herdr))
            guard result.exitCode == 0 else { throw PushPluginError.pluginUninstallFailed(result.message) }
        }
        try await marker.restore { _, current, _ in current }
    }

    public func updateMuted(_ muted: Set<String>) async throws {
        let files = HostFiles(channel: channel)
        let read = try await files.read([pairingPath])
        guard case .file(let data, let version)? = read[pairingPath], var file = PushPairingFile(contents: data) else {
            throw PushPluginError.notPaired
        }
        file.muted = muted
        try await files.apply([.write(pairingPath, file.contents, expecting: .version(version))])
    }

    /// Purrdr 裝的外掛已裝且版本落後 `PushPluginRelease.latestKnownVersion` 才 `herdr plugin update`(#432);沒裝不代裝，
    /// 讀不懂版本(Demo 主機)不動。呼叫端負責頻率上限。
    public func updatePluginIfNeeded() async throws -> Bool {
        // 只更新 Purrdr 裝的外掛(有 `~/.purrdr/push-plugin/` 的安裝紀錄,同 `remove()` 的判斷);使用者自己裝的不動(ADR-0002)。
        guard try await ReversibleHostWrite(channel: channel, feature: Self.pluginFeature).inspect().isInstalled else { return false }
        let list = try await run(HerdrCommand.pluginList(id: Self.pluginID, herdr: herdr))
        guard list.exitCode == 0 else { throw PushPluginError.pluginListFailed(list.message) }
        guard let installed = Self.installedVersion(in: list.stdout), installed < PushPluginRelease.latestKnownVersion else { return false }
        let result = try await run(HerdrCommand.pluginUpdate(id: Self.pluginID, herdr: herdr), deadline: HostCommandDeadline.download)
        guard result.exitCode == 0 else { throw PushPluginError.pluginUpdateFailed(result.message) }
        return true
    }

    /// `herdr plugin list --json` 裡這個外掛的版本;沒裝或版本看不懂是 `nil`。
    static func installedVersion(in output: String) -> HostServiceVersion? {
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let plugins = ((root["result"] as? [String: Any])?["plugins"] ?? root["plugins"]) as? [[String: Any]] ?? []
            if let plugin = plugins.first(where: { $0["plugin_id"] as? String == pluginID }), let text = plugin["version"] as? String {
                return HostServiceVersion(text)
            }
        }
        return nil
    }

    // MARK: - 主機指令

    func pluginInstalled() async throws -> Bool {
        let result = try await run(HerdrCommand.pluginList(id: Self.pluginID, herdr: herdr))
        guard result.exitCode == 0 else { throw PushPluginError.pluginListFailed(result.message) }
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
