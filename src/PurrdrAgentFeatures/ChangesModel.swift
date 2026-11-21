import Foundation
import Observation
import PurrdrCore

/// 變更頁讀不到的原因(畫面依它說明)。
public enum ChangesProblem: Sendable, Equatable {
    /// 這種連線方式或主機讀不了(Windows 主機、Demo 以外沒有 git 的主機…)。
    case unsupported
    case notGitRepository
    /// 主機服務：Agent 已換資料夾或結束。
    case agentMoved
    /// 主機上沒有 git(SSH)。
    case gitNotInstalled
    /// HTTPS 主機的主機服務太舊。
    case hostServiceUpdateRequired(installedVersion: String?)
    case failed

    init(_ error: any Error) {
        switch error {
        case GitChangesError.unsupported: self = .unsupported
        case GitChangesError.notGitRepository: self = .notGitRepository
        case GitChangesError.cwdNotAllowed: self = .agentMoved
        case GitChangesError.gitNotInstalled: self = .gitNotInstalled
        case HostServiceError.hostServiceUpdateRequired(_, let installedVersion): self = .hostServiceUpdateRequired(installedVersion: installedVersion)
        default: self = .failed
        }
    }
}

/// 變更頁(#310,DESIGN.md「變更頁」):Agent 工作目錄的 git 變更清單(種類、+/−)→ 單檔 diff;
/// 在 diff 的行上寫評論，最後組成一則訊息交給聊天的送出管線(`ConversationModel.sendReview`)。
@MainActor
@Observable
public final class ChangesModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case loaded
        case failed(ChangesProblem)
    }

    /// 變更清單的一列。
    public struct ChangedFile: Sendable, Equatable, Identifiable {
        public var path: String
        public var kind: GitChangeKind
        /// 有 diff 文字時的 +/− 行數。
        public var stats: GitDiffStats?

        public var id: String { path }
    }

    /// 一個檔案的 diff 狀態。
    public enum FileDiff: Sendable, Equatable {
        case loading
        case lines([GitDiffLine])
        case omitted(GitDiffOmission)
        case failed(ChangesProblem)
    }

    /// Agent 的工作目錄。
    public let cwd: String
    public private(set) var phase: Phase = .loading
    public private(set) var branch: String?
    public private(set) var files: [ChangedFile] = []
    /// 依寫下的順序;送出時依檔案與行的順序排。
    public private(set) var comments: [GitReviewComment] = []
    private var diffs: [String: FileDiff] = [:]
    /// 全部 diff 總量達上限：標成過大的檔案要單獨再讀。
    private var truncated = false

    private let reader: any GitChangesReading
    private let canSend: @MainActor () -> Bool

    /// - Parameter canSend: 聊天現在能不能送出(唯讀裝置、離線、Agent 不在時不能)。
    public init(reader: any GitChangesReading, cwd: String, canSend: @escaping @MainActor () -> Bool) {
        self.reader = reader
        self.cwd = cwd
        self.canSend = canSend
    }

    /// 讀變更清單與全部 diff(算 +/−,點進檔案時不用再讀)。
    public func load() async {
        phase = .loading
        do {
            async let status = reader.gitStatus(cwd: cwd)
            async let all = reader.gitDiff(cwd: cwd, path: nil)
            let (loadedStatus, loadedDiffs) = try await (status, all)
            truncated = loadedDiffs.truncated
            var byPath: [String: FileDiff] = [:]
            for file in loadedDiffs.files { byPath[file.path] = Self.fileDiff(file.content) }
            diffs = byPath
            branch = loadedStatus.branch
            files = loadedStatus.files.map { change in
                var stats: GitDiffStats?
                if case .lines(let lines)? = byPath[change.path] { stats = GitDiffStats(lines) }
                return ChangedFile(path: change.path, kind: change.kind, stats: stats)
            }
            phase = .loaded
        } catch {
            phase = .failed(ChangesProblem(error))
        }
    }

    /// 打開單檔 diff:已讀過的直接用;還沒讀到、或總量截斷而標成過大的檔案單獨再讀一次。
    public func loadDiff(of path: String) async {
        switch diffs[path] {
        case .lines?, .omitted(.binary)?, .omitted(.excluded)?: return
        case .omitted(.tooLarge)? where !truncated: return
        default: break
        }
        diffs[path] = .loading
        do {
            let result = try await reader.gitDiff(cwd: cwd, path: path)
            guard let file = result.files.first(where: { $0.path == path }) else {
                diffs[path] = .failed(.failed)
                return
            }
            diffs[path] = Self.fileDiff(file.content)
            if case .lines(let lines) = diffs[path], let index = files.firstIndex(where: { $0.path == path }) {
                files[index].stats = GitDiffStats(lines)
            }
        } catch {
            diffs[path] = .failed(ChangesProblem(error))
        }
    }

    public func diff(of path: String) -> FileDiff { diffs[path] ?? .loading }

    public func comment(on line: GitDiffLine, in path: String) -> GitReviewComment? {
        comments.first { $0.path == path && $0.line.id == line.id }
    }

    /// 寫下或改寫某一行的評論;空白是刪除。標頭與附註不能評論。
    public func setComment(_ body: String, on line: GitDiffLine, in path: String) {
        guard line.isCommentable else { return }
        let index = comments.firstIndex { $0.path == path && $0.line.id == line.id }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let index { comments.remove(at: index) }
        } else if let index {
            comments[index].body = body
        } else {
            comments.append(GitReviewComment(path: path, line: line, body: body))
        }
    }

    /// 有評論的檔案數。
    public var commentedFileCount: Int { Set(comments.map(\.path)).count }

    /// 聊天現在能不能送出(唯讀裝置、離線、Agent 不在時不能);評論照樣可以寫。
    public var canSendReview: Bool { canSend() }

    /// 組成要送的訊息並清空評論;不能送出或沒有評論時是 `nil`(評論留著)。
    public func takeReview() -> String? {
        guard canSendReview, !comments.isEmpty else { return nil }
        let message = GitReviewMessage.compose(comments, fileOrder: files.map(\.path))
        guard !message.isEmpty else { return nil }
        comments = []
        return message
    }

    private static func fileDiff(_ content: GitFileDiff.Content) -> FileDiff {
        switch content {
        case .hunks(let text): .lines(GitDiffLines.parse(text))
        case .omitted(let reason): .omitted(reason)
        }
    }
}
