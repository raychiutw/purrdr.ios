import Foundation
import PurrdrCore

/// HTTPS 主機的變更頁(#310):主機服務的 `git.status`／`git.diff`(0.7.0 起，`HostServiceFeature.gitChanges`)。
/// 主機服務以程序內函式庫讀取、不執行 git;`cwd` 必須是 herdr 當下回報的 Agent 工作目錄(raychiutw/purrdr.host#33)。
/// 版本不足丟 `HostServiceError.hostServiceUpdateRequired`(畫面提示更新主機服務)。
extension HTTPSHostConnection: GitChangesReading {
    public func gitStatus(cwd: String) async throws -> GitWorkingTreeStatus {
        try await requireHostService(.gitChanges)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .gitStatus(.init(requestId: $0, cwd: cwd)) }
        }
        guard case .gitStatusResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return GitWorkingTreeStatus(branch: result.branch, files: result.files.map { GitChange(path: $0.path, kind: $0.change) })
    }

    public func gitDiff(cwd: String, path: String?) async throws -> GitDiffSet {
        try await requireHostService(.gitChanges)
        // diff 合計最多 x-maximum-file-size:以它估算傳輸時間。
        let reply = try await withDeadline(HostCommandDeadline.transfer(bytes: HostServiceProtocol.maximumFileSize)) {
            try await self.send { .gitDiff(.init(requestId: $0, cwd: cwd, path: path)) }
        }
        guard case .gitDiffResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        let files = try result.files.map { file -> GitFileDiff in
            if let omitted = file.omitted { return GitFileDiff(path: file.path, kind: file.change, content: .omitted(omitted)) }
            guard let diff = file.diff else { throw HostServiceError.unexpectedResponse }
            return GitFileDiff(path: file.path, kind: file.change, content: .hunks(diff))
        }
        return GitDiffSet(files: files, truncated: result.truncated)
    }
}
