import Foundation
import PurrdrCore

/// SSH 主機的變更頁(#310):經主機通道跑唯讀 git 指令(一次性指令，經 `runOnce` 與主機腳本時限)。
///
/// 唯讀：`GIT_OPTIONAL_LOCKS=0` 讓 `git status` 不更新 index、不留 lock;diff 加 `--no-ext-diff --no-textconv`,不跑外部 diff 程式。
/// 排除清單(`HostFileAccessPolicy`,與主機取檔、主機服務同一份)裡的檔案不讀 diff,路徑也不送到主機。
/// Windows 主機的通道不認得這份 POSIX 腳本(`WindowsCommandError.unsupported`),Demo 主機不認得時 exit 127:都回 `unsupported`。
public struct SSHGitChanges: GitChangesReading {
    /// diff 的大小上限(bytes):超過單檔上限的檔案、總量達上限之後的檔案標成過大。
    public struct Limits: Sendable, Equatable {
        public var fileBytes: Int
        public var totalBytes: Int

        public init(fileBytes: Int, totalBytes: Int) {
            self.fileBytes = fileBytes
            self.totalBytes = totalBytes
        }

        /// 手機上讀 diff:單檔 1 MiB、合計 4 MiB(主機服務是合計 `x-maximum-file-size`)。
        public static let standard = Limits(fileBytes: 1024 * 1024, totalBytes: 4 * 1024 * 1024)
    }

    let channel: any HostChannel
    let limits: Limits
    let sleep: Sleep

    public init(channel: any HostChannel, limits: Limits = .standard, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.limits = limits
        self.sleep = sleep
    }

    public func gitStatus(cwd: String) async throws -> GitWorkingTreeStatus {
        try await readStatus(cwd: cwd).status
    }

    public func gitDiff(cwd: String, path: String?) async throws -> GitDiffSet {
        let loaded = try await readStatus(cwd: cwd)
        return try await readDiff(cwd: cwd, loaded: loaded, path: path)
    }

    /// 第一次載入:一次清單加一次 diff(diff 用同一份清單,不再重跑 status)。
    public func gitChanges(cwd: String) async throws -> (status: GitWorkingTreeStatus, diffs: GitDiffSet) {
        let loaded = try await readStatus(cwd: cwd)
        return (loaded.status, try await readDiff(cwd: cwd, loaded: loaded, path: nil))
    }

    private func readStatus(cwd: String) async throws -> (status: GitWorkingTreeStatus, root: String) {
        let result = try await run(GitChangesCommand.status(cwd: cwd), deadline: HostCommandDeadline.standard)
        return try GitChangesCommand.parseStatus(result.stdout)
    }

    private func readDiff(cwd: String, loaded: (status: GitWorkingTreeStatus, root: String), path: String?) async throws -> GitDiffSet {
        var files = loaded.status.files
        if let path { files = files.filter { $0.path == path } }
        // git 的路徑相對 repo 根目錄:排除清單比對「根目錄加相對路徑」,不是工作目錄加路徑。
        let separator = loaded.root.hasSuffix("/") ? "" : "/"
        let excluded = Set(files.filter { HostFileAccessPolicy.isExcluded(loaded.root + separator + $0.path) }.map(\.path))
        let requested = files.filter { !excluded.contains($0.path) }
        var sections: [Int: Data] = [:]
        var truncated = false
        if !requested.isEmpty {
            let marker = "purrdr-diff-" + UUID().uuidString
            let command = GitChangesCommand.diff(cwd: cwd, marker: marker, limits: limits, files: requested)
            let result = try await run(command, deadline: HostCommandDeadline.transfer(bytes: limits.totalBytes))
            truncated = result.stdout.count > limits.totalBytes
            sections = GitChangesCommand.sections(result.stdout, marker: marker)
            // 總量達上限：最後一段被截斷。
            if truncated, let last = sections.keys.max() { sections[last] = nil }
        }
        var index = 0
        let diffs = files.map { file -> GitFileDiff in
            guard !excluded.contains(file.path) else { return GitFileDiff(path: file.path, kind: file.kind, content: .omitted(.excluded)) }
            defer { index += 1 }
            guard let section = sections[index] else { return GitFileDiff(path: file.path, kind: file.kind, content: .omitted(.tooLarge)) }
            guard section.count <= limits.fileBytes else { return GitFileDiff(path: file.path, kind: file.kind, content: .omitted(.tooLarge)) }
            return GitFileDiff(path: file.path, kind: file.kind, content: GitChangesCommand.content(of: section))
        }
        return GitDiffSet(files: diffs, truncated: truncated)
    }

    private func run(_ command: String, deadline: Duration) async throws -> CommandResult {
        let result: CommandResult
        do {
            result = try await channel.collect(command, deadline: deadline, sleep: sleep)
        } catch is WindowsCommandError {
            throw GitChangesError.unsupported
        }
        switch result.exitStatus {
        case .some(0): return result
        case .some(GitChangesCommand.notRepositoryExitCode): throw GitChangesError.notGitRepository
        case .some(GitChangesCommand.noGitExitCode): throw GitChangesError.gitNotInstalled
        // 工作目錄已不存在(Agent 換了資料夾或刪掉):與主機服務的 cwd_not_allowed 同一個說明。
        case .some(GitChangesCommand.missingFolderExitCode): throw GitChangesError.cwdNotAllowed
        case .some(GitChangesCommand.usageExitCode): throw GitChangesError.failed("unexpected arguments for the git script")
        case .some(127): throw GitChangesError.unsupported
        default:
            throw GitChangesError.failed(String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// 變更頁的主機指令(Demo 主機以 `request(in:)` 認出來回應)。
public enum GitChangesCommand {
    static let notRepositoryExitCode: Int32 = 65
    static let missingFolderExitCode: Int32 = 66
    static let noGitExitCode: Int32 = 69
    static let usageExitCode: Int32 = 64
    private static let tag = "purrdr-git"

    /// 參數：`status 工作目錄` 或 `diff 工作目錄 標記 單檔上限 總量上限 (種類 路徑)…`。
    static let script = HostScriptTimeLimit.posixRead("""
        PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH
        GIT_OPTIONAL_LOCKS=0
        GIT_TERMINAL_PROMPT=0
        LC_ALL=C
        export PATH GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT LC_ALL
        command -v git >/dev/null 2>&1 || exit \(noGitExitCode)
        cd -- "$2" 2>/dev/null || exit \(missingFolderExitCode)
        root=$(git rev-parse --show-toplevel 2>/dev/null) || exit \(notRepositoryExitCode)
        cd -- "$root" || exit \(missingFolderExitCode)
        case $1 in
        status)
          printf 'branch %s\\nroot %s\\n' "$(git symbolic-ref --short -q HEAD)" "$root"
          git -c core.quotepath=off status --porcelain=v1 -z --untracked-files=all --no-renames --ignore-submodules=all
          ;;
        diff)
          marker=$3
          file=$4
          total=$5
          shift 5
          base=HEAD
          git rev-parse -q --verify HEAD >/dev/null 2>&1 || base=4b825dc642cb6eb9a060e54bf8d69288fbee4904
          index=0
          while [ $# -ge 2 ]; do
            printf '\\n%s %s\\n' "$marker" "$index"
            if [ "$1" = untracked ]; then
              git diff --no-index --no-color --no-ext-diff --no-textconv -U3 -- /dev/null "$2"
            else
              git diff --no-color --no-ext-diff --no-textconv -U3 "$base" -- "$2"
            fi | head -c $((file + 1))
            index=$((index + 1))
            shift 2
          done | head -c $((total + 1))
          ;;
        *) exit \(usageExitCode) ;;
        esac
        """)

    public static func status(cwd: String) -> String {
        command(["status", cwd])
    }

    static func diff(cwd: String, marker: String, limits: SSHGitChanges.Limits, files: [GitChange]) -> String {
        command(["diff", cwd, marker, String(limits.fileBytes), String(limits.totalBytes)] + files.flatMap { [$0.kind.rawValue, $0.path] })
    }

    private static func command(_ arguments: [String]) -> String {
        (["/bin/sh", "-c", PosixShell.quote(script), tag] + arguments.map(PosixShell.quote)).joined(separator: " ")
    }

    /// 認得的變更頁指令(Demo 主機用)。
    public enum Request: Sendable, Equatable {
        case status(cwd: String)
        /// 依序要 diff 的檔案(路徑、種類)與分段標記。
        case diff(cwd: String, marker: String, files: [GitChange])
    }

    /// `status(cwd:)`／`diff` 的反向：認得就回傳參數，其他指令回 `nil`。
    public static func request(in command: String) -> Request? {
        let prefix = ["/bin/sh", "-c", PosixShell.quote(script), tag].joined(separator: " ") + " "
        guard command.hasPrefix(prefix), let arguments = PosixShell.unquote(String(command.dropFirst(prefix.count))),
              arguments.count >= 2 else { return nil }
        switch arguments[0] {
        case "status" where arguments.count == 2:
            return .status(cwd: arguments[1])
        case "diff" where arguments.count >= 5 && (arguments.count - 5).isMultiple(of: 2):
            let pairs = stride(from: 5, to: arguments.count, by: 2).compactMap { index in
                GitChangeKind(rawValue: arguments[index]).map { GitChange(path: arguments[index + 1], kind: $0) }
            }
            return .diff(cwd: arguments[1], marker: arguments[2], files: pairs)
        default:
            return nil
        }
    }

    /// `status` 的輸出(Demo 主機用):分支與 repo 根目錄各一行，之後是 porcelain v1 `-z` 的項目。
    public static func statusOutput(_ status: GitWorkingTreeStatus, root: String) -> Data {
        var output = Data("branch \(status.branch ?? "")\nroot \(root)\n".utf8)
        for file in status.files {
            let code = switch file.kind {
            case .added: "A "
            case .modified: " M"
            case .deleted: " D"
            case .untracked: "??"
            }
            output.append(Data("\(code) \(file.path)\u{0}".utf8))
        }
        return output
    }

    /// `diff` 的輸出(Demo 主機用):每個檔案一段 git diff 的輸出。
    public static func diffOutput(marker: String, diffs: [String]) -> Data {
        Data(diffs.enumerated().map { "\n\(marker) \($0.offset)\n\($0.element)" }.joined().utf8)
    }

    static func parseStatus(_ stdout: Data) throws -> (status: GitWorkingTreeStatus, root: String) {
        let malformed = GitChangesError.failed("malformed git status output")
        guard let branchEnd = stdout.firstIndex(of: 0x0A) else { throw malformed }
        let branchLine = String(decoding: stdout[..<branchEnd], as: UTF8.self)
        let afterBranch = stdout.index(after: branchEnd)
        guard branchLine.hasPrefix("branch "), let rootEnd = stdout[afterBranch...].firstIndex(of: 0x0A) else { throw malformed }
        let rootLine = String(decoding: stdout[afterBranch..<rootEnd], as: UTF8.self)
        guard rootLine.hasPrefix("root ") else { throw malformed }
        let branch = String(branchLine.dropFirst("branch ".count))
        let root = String(rootLine.dropFirst("root ".count))
        let newline = rootEnd
        let entries = stdout[stdout.index(after: newline)...].split(separator: 0, omittingEmptySubsequences: true)
        let files = entries.compactMap { entry -> GitChange? in
            let text = String(decoding: entry, as: UTF8.self)
            guard text.count > 3 else { return nil }
            let x = text[text.startIndex], y = text[text.index(after: text.startIndex)]
            let path = String(text.dropFirst(3))
            let kind: GitChangeKind
            switch (x, y) {
            case ("?", "?"): kind = .untracked
            case ("!", "!"): return nil
            // 加入 index 後又從工作目錄刪掉:相對 HEAD 沒有變更。
            case ("A", "D"): return nil
            case ("A", _): kind = .added
            case ("D", _), (_, "D"): kind = .deleted
            default: kind = .modified
            }
            return GitChange(path: path, kind: kind)
        }
        return (GitWorkingTreeStatus(branch: branch.isEmpty ? nil : branch, files: files.sorted { $0.path < $1.path }), root)
    }

    /// 依標記切開每個檔案的輸出：序號 → 那段 bytes。
    static func sections(_ stdout: Data, marker: String) -> [Int: Data] {
        let separator = Data("\n\(marker) ".utf8)
        var sections: [Int: Data] = [:]
        var rest = stdout[...]
        guard let first = rest.firstRange(of: separator) else { return [:] }
        rest = rest[first.upperBound...]
        while !rest.isEmpty {
            let next = rest.firstRange(of: separator)
            let chunk = rest[..<(next?.lowerBound ?? rest.endIndex)]
            if let newline = chunk.firstIndex(of: 0x0A), let index = Int(String(decoding: chunk[..<newline], as: UTF8.self)) {
                sections[index] = Data(chunk[chunk.index(after: newline)...])
            }
            guard let next else { break }
            rest = rest[next.upperBound...]
        }
        return sections
    }

    /// 一段 git diff 的輸出：去掉檔頭，只留 `@@` 起的 hunk;二進位檔(git 的說明或不是 UTF-8)不顯示。
    static func content(of section: Data) -> GitFileDiff.Content {
        guard let text = String(data: section, encoding: .utf8) else { return .omitted(.binary) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("@@") }) else {
            let header = lines.contains { $0.hasPrefix("Binary files ") || $0.hasPrefix("GIT binary patch") }
            return header ? .omitted(.binary) : .hunks("")
        }
        return .hunks(lines[start...].joined(separator: "\n"))
    }
}
