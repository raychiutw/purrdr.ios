import Foundation
import PurrdrCore

/// 主機檔案：一次往返讀多個檔案;一次往返以 compare-and-swap 寫多個檔案。
///
/// `readsOverLongRunningChannel` 時讀取經一條長駐通道(#203,`HostFileScript.follow`):請求一行，腳本只送一次;
/// 這個值的複本共用同一條。主機跑不了這支腳本時退回一次性讀取。寫入與找最新檔一律是一次性指令。
public struct HostFiles: Sendable {
    let channel: any HostChannel
    /// 指令期限的計時(測試注入)。
    let sleep: Sleep
    private let longRunning: LongRunningScriptChannel<Data>?

    /// - Parameters:
    ///   - readsOverLongRunningChannel: 讀取經長駐通道(定期讀主題、註記、用量的每台主機共用一份)。
    ///   - diagnostics: 退回一次性讀取的原因(交給系統紀錄)。
    public init(
        channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task, readsOverLongRunningChannel: Bool = false,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.channel = channel
        self.sleep = sleep
        longRunning = nil
    }

    /// 一次往返讀取 `paths`(跟隨 symlink)。每個檔案最多 1 MiB。
    public func read(_ paths: [HostPath]) async throws -> HostFileRead {
        try paths.forEach { try $0.validate() }
        if let read = try await readOverLongRunningChannel(paths, known: [:]) { return read }
        let result = try await run(HostFileScript.read, arguments: paths.map(\.relative))
        guard result.exitCode == 0 else { throw HostFilesError.failed(exitCode: result.exitCode, message: result.stderrText) }
        return try HostFileScript.parseRead(result.stdout, paths: paths)
    }

    /// 條件式讀取：`knownVersions` 裡版本沒變的檔案只回報在 `HostFileRead.unchanged`,不傳內容。
    /// 沒有任何已知版本時就是一般的 `read`。
    public func read(_ paths: [HostPath], knownVersions: [HostPath: HostFileVersion]) async throws -> HostFileRead {
        guard !knownVersions.isEmpty else { return try await read(paths) }
        try paths.forEach { try $0.validate() }
        if let read = try await readOverLongRunningChannel(paths, known: knownVersions) { return read }
        let arguments = paths.flatMap { [$0.relative, knownVersions[$0]?.checksum ?? HostFileScript.unknownVersion] }
        let result = try await run(HostFileScript.readIfChanged, arguments: arguments)
        guard result.exitCode == 0 else { throw HostFilesError.failed(exitCode: result.exitCode, message: result.stderrText) }
        return try HostFileScript.parseRead(result.stdout, paths: paths)
    }

    /// 一次往返找 `directory` 裡檔名以 `prefix` 開頭、`suffix` 結尾、最新(修改時間)的可讀一般檔案;沒有是 `nil`。
    /// 檔名含不安全字元(`HostPath` 不接受)時丟 `HostFilesError.invalidPath`。
    public func newest(in directory: HostPath, prefix: String, suffix: String) async throws -> HostPath? {
        try directory.validate()
        try HostPath(directory.relative + "/" + prefix + "x" + suffix).validate()
        let result = try await run(HostFileScript.newest, arguments: [directory.relative, prefix, suffix])
        guard result.exitCode == 0 else { throw HostFilesError.failed(exitCode: result.exitCode, message: result.stderrText) }
        return try HostFileScript.parseNewest(result.stdout)
    }

    /// 一次往返套用 `changes`:先檢查每個檔案都還是預期的版本，全部符合才依序寫入(compare-and-swap)。
    ///
    /// 有一個不符就整批不寫，丟 `HostFilesError.changedSinceRead`。寫入用同資料夾的暫存檔再 `mv`,
    /// 所以讀的人不會看到寫一半的檔案;覆寫既有檔案時保留它的權限。
    public func apply(_ changes: [HostFileChange]) async throws {
        try changes.forEach { try $0.validate() }
        let result = try await run(HostFileScript.apply, arguments: changes.flatMap(\.scriptArguments))
        let detail = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        switch result.exitCode {
        case 0: return
        case HostFileRequest.ExitCode.changedSinceRead where detail.hasPrefix("changed "): throw HostFilesError.changedSinceRead(HostPath(String(detail.dropFirst("changed ".count))))
        case HostFileRequest.ExitCode.missingDirectory where detail.hasPrefix("nodir "): throw HostFilesError.missingDirectory(HostPath(String(detail.dropFirst("nodir ".count))))
        default: throw HostFilesError.failed(exitCode: result.exitCode, message: result.stderrText)
        }
    }

    /// 經長駐通道讀;沒有長駐通道或主機跑不了腳本時是 `nil`(改用一次性讀取)。
    private func readOverLongRunningChannel(_ paths: [HostPath], known: [HostPath: HostFileVersion]) async throws -> HostFileRead? {
        guard let longRunning else { return nil }
        do {
            switch try await longRunning.request(HostFileScript.followRequest(paths, known: known)) {
            case .reply(let output): return try HostFileScript.parseRead(output, paths: paths)
            case .unsupported: return nil
            }
        } catch let ended as LongRunningScriptChannel<Data>.Ended {
            throw HostFilesError.failed(exitCode: ended.exitCode ?? -1, message: "")
        }
    }

    private func run(_ script: String, arguments: [String]) async throws -> CommandResult {
        let command = HostFileScript.command(script, arguments: arguments)
        guard command.utf8.count <= HostFileScript.maximumCommandLength else { throw HostFilesError.tooLarge }
        return try await channel.collect(command, deadline: HostCommandDeadline.standard, sleep: sleep)
    }
}
