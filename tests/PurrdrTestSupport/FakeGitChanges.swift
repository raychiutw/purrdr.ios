import Foundation
import PurrdrCore

/// 變更頁(#310)的假 git 讀取：回設定好的變更清單與 diff(或錯誤),`requests` 是收到的請求。
public actor FakeGitChanges: GitChangesReading {
    public enum Request: Sendable, Equatable {
        case status(cwd: String)
        case diff(cwd: String, path: String?)
    }

    private let status: GitWorkingTreeStatus
    /// 全部檔案的 diff(`path` 是 `nil`)。
    private let allDiffs: GitDiffSet
    private let failure: (any Error & Sendable)?
    /// 單檔 diff:路徑 → 結果;沒設定時從 `allDiffs` 取那個檔案。
    private var fileDiffs: [String: GitDiffSet] = [:]
    public private(set) var requests: [Request] = []

    public init(status: GitWorkingTreeStatus, diffs: GitDiffSet) {
        self.status = status
        allDiffs = diffs
        failure = nil
    }

    public init(failing error: any Error & Sendable) {
        status = GitWorkingTreeStatus(branch: nil, files: [])
        allDiffs = GitDiffSet(files: [], truncated: false)
        failure = error
    }

    public func setFileDiff(_ diff: GitDiffSet, for path: String) {
        fileDiffs[path] = diff
    }

    public func gitStatus(cwd: String) async throws -> GitWorkingTreeStatus {
        requests.append(.status(cwd: cwd))
        if let failure { throw failure }
        return status
    }

    public func gitDiff(cwd: String, path: String?) async throws -> GitDiffSet {
        requests.append(.diff(cwd: cwd, path: path))
        if let failure { throw failure }
        guard let path else { return allDiffs }
        if let diff = fileDiffs[path] { return diff }
        return GitDiffSet(files: allDiffs.files.filter { $0.path == path }, truncated: false)
    }
}
