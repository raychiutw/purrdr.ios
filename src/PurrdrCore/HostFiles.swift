import Foundation

/// 主機上的一個檔案路徑，相對於家目錄(例如 `.claude/settings.json`)。
public struct HostPath: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let relative: String

    public init(_ relative: String) { self.relative = relative }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { "~/" + relative }
}

/// 讀到的檔案版本：主機上 `cksum` 的結果(CRC 與大小)。只用來比對「讀取之後有沒有被改過」。
public struct HostFileVersion: Hashable, Sendable {
    public let checksum: String
    public init(checksum: String) { self.checksum = checksum }
}

/// 主機上一個檔案的狀態。
public enum HostFileState: Equatable, Sendable {
    /// 不存在，但所在的資料夾存在。
    case missing
    /// 不存在，連所在的資料夾也不存在。
    case missingDirectory
    case file(Data, version: HostFileVersion)
    /// 是資料夾、FIFO、裝置等，不是一般檔案(讀 FIFO 會卡住 SSH,行為規格 R-F03)。
    case notRegularFile
    case unreadable
    case tooLarge

    public var contents: Data? {
        if case .file(let data, _) = self { return data }
        return nil
    }
}

/// 一次讀取的結果。
public struct HostFileRead: Equatable, Sendable {
    /// 執行指令的主機使用者(同意畫面要說明「以哪個使用者」修改)。
    public var user: String
    public var files: [HostPath: HostFileState]

    public init(user: String, files: [HostPath: HostFileState]) {
        self.user = user
        self.files = files
    }

    public subscript(path: HostPath) -> HostFileState? { files[path] }
}

/// 主機檔案：一次往返讀多個檔案;一次往返以 compare-and-swap 寫多個檔案。
public struct HostFiles: Sendable {
    let channel: any HostChannel

    public init(channel: any HostChannel) {
        self.channel = channel
    }

    /// 一次往返讀取 `paths`(跟隨 symlink)。每個檔案最多 1 MiB。
    public func read(_ paths: [HostPath]) async throws -> HostFileRead {
        try paths.forEach { try $0.validate() }
        let result = try await run(HostFileScript.read, arguments: paths.map(\.relative))
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

    private func run(_ script: String, arguments: [String]) async throws -> CommandResult {
        let command = HostFileScript.command(script, arguments: arguments)
        guard command.utf8.count <= HostFileScript.maximumCommandLength else { throw HostFilesError.tooLarge }
        let session = try await channel.execute(command)
        await session.closeStdin()
        var result = CommandResult()
        for try await event in session.output {
            switch event {
            case .stdout(let data): result.stdout.append(data)
            case .stderr(let data): result.stderr.append(data)
            case .exit(let code, _): result.exitCode = code
            }
        }
        return result
    }
}

/// 寫入前對檔案目前版本的預期。
public enum HostFileExpectation: Equatable, Sendable {
    /// 不管目前是什麼(只用在 Purrdr 自己的檔案)。
    case anything
    case missing
    case version(HostFileVersion)
}

/// 一個檔案變更。
public enum HostFileChange: Equatable, Sendable {
    case write(HostPath, Data, executable: Bool = false, expecting: HostFileExpectation)
    case delete(HostPath, expecting: HostFileExpectation)
    /// 移除 Purrdr 自己的資料夾(必須在 `.purrdr/` 底下);`.purrdr` 因此變空時一起移除。
    case removeDirectory(HostPath)
    /// 建立一個原本不存在的資料夾(例如 Codex 啟動器的 `~/.local/bin`)。已經存在 → 整批不寫(`changedSinceRead`)。
    /// 同一批之後寫在它底下的檔案視為資料夾存在。
    case makeDirectory(HostPath)
    /// 資料夾是空的才移除(還原時拿掉自己建的資料夾);使用者後來放了東西就保留，不算失敗。
    case removeEmptyDirectory(HostPath)

    public var path: HostPath {
        switch self {
        case .write(let path, _, _, _), .delete(let path, _), .removeDirectory(let path), .makeDirectory(let path), .removeEmptyDirectory(let path): path
        }
    }
}

public enum HostFilesError: Error, Equatable {
    /// 路徑必須相對於家目錄、不含 `..`、只用安全字元。
    case invalidPath(String)
    /// 指令(含 base64 內容)超過 sshd 單一參數的上限(行為規格 §3.2)。
    case tooLarge
    /// 讀取之後檔案被改過(或預期不存在卻存在):整批都沒寫。
    case changedSinceRead(HostPath)
    /// 要寫的檔案所在的資料夾不存在(只有 `.purrdr/` 底下會自動建立;其他地方要同一批先 `makeDirectory`)。
    case missingDirectory(HostPath)
    /// 主機上的輸出不是預期的格式。
    case malformedOutput
    /// 主機腳本失敗(非零 exit)。
    case failed(exitCode: Int32, message: String)
}

struct CommandResult {
    var stdout = Data()
    var stderr = Data()
    var exitCode: Int32 = -1
    /// Windows 主機的 CLIXML／Rust Debug 格式整理過(`WindowsErrorText`);其他主機只去掉前後空白。
    var stderrText: String { WindowsErrorText.readable(String(decoding: stderr, as: UTF8.self)) }
}

extension HostFileChange {
    func validate() throws {
        try path.validate()
        if case .removeDirectory(let path) = self, !path.relative.hasPrefix(".purrdr/") { throw HostFilesError.invalidPath(path.relative) }
    }

    /// 主機腳本的參數：每個變更固定五個(種類、路徑、預期、base64 內容、是否可執行)。
    var scriptArguments: [String] {
        switch self {
        case .write(let path, let data, let executable, let expectation):
            ["put", path.relative, expectation.scriptArgument, data.base64EncodedString(), executable ? "1" : "0"]
        case .delete(let path, let expectation):
            ["del", path.relative, expectation.scriptArgument, "", "0"]
        case .removeDirectory(let path):
            ["rmtree", path.relative, "any", "", "0"]
        case .makeDirectory(let path):
            ["mkdir", path.relative, "missing", "", "0"]
        case .removeEmptyDirectory(let path):
            ["rmdir", path.relative, "any", "", "0"]
        }
    }
}

extension HostFileExpectation {
    var scriptArgument: String {
        switch self {
        case .anything: "any"
        case .missing: "missing"
        case .version(let version): version.checksum
        }
    }
}

extension HostPath {
    /// 只接受家目錄底下、由安全字元組成的相對路徑。這些路徑會原樣交給主機腳本。
    func validate() throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        let segments = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, relative.allSatisfy(allowed.contains),
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw HostFilesError.invalidPath(relative) }
    }
}
