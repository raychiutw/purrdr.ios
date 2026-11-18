import Foundation
import PurrdrCore

/// 主機檔案：一次往返讀多個檔案;一次往返以 compare-and-swap 寫多個檔案。
public struct HostFiles: Sendable {
    let channel: any HostChannel
    /// 指令期限的計時(測試注入)。
    let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.sleep = sleep
    }

    /// 一次往返讀取 `paths`(跟隨 symlink)。每個檔案最多 1 MiB。
    public func read(_ paths: [HostPath]) async throws -> HostFileRead {
        try paths.forEach { try $0.validate() }
        let result = try await run(HostFileScript.read, arguments: paths.map(\.relative))
        guard result.exitCode == 0 else { throw HostFilesError.failed(exitCode: result.exitCode, message: result.stderrText) }
        return try HostFileScript.parseRead(result.stdout, paths: paths)
    }

    /// 條件式讀取：`knownVersions` 裡版本沒變的檔案只回報在 `HostFileRead.unchanged`,不傳內容。
    public func read(_ paths: [HostPath], knownVersions: [HostPath: HostFileVersion]) async throws -> HostFileRead {
        try await read(paths)
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

    private func run(_ script: String, arguments: [String]) async throws -> CommandResult {
        let command = HostFileScript.command(script, arguments: arguments)
        guard command.utf8.count <= HostFileScript.maximumCommandLength else { throw HostFilesError.tooLarge }
        return try await channel.collect(command, deadline: HostCommandDeadline.standard, sleep: sleep)
    }
}
