import Foundation
import PurrdrCore

/// HTTPS 主機的方案用量、session context、用量擷取與資料夾瀏覽(主機服務 0.12.0 起,#416)。
/// 只接協定與版本門檻;畫面在各自的票。版本不足丟 `HostServiceError.hostServiceUpdateRequired`(送出前檢查,不送出)。
/// 用量擷取的安裝與還原是寫入類,唯讀裝置丟 `HostServiceError.readOnlyDevice`。
extension HTTPSHostConnection {
    /// 主機使用者家目錄(`welcome.home_directory`):`directory.list` 的起點。舊版主機服務或找不到家目錄時是 `nil`。
    public func homeDirectory() async throws -> String? {
        try await hostServiceInfo().homeDirectory
    }

    /// Codex 的方案用量(`usage.codex`)。
    public func codexUsage() async throws -> HostServiceProtocol.UsageCodexResult {
        try await requireHostService(.planUsage)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.sendKeepingErrors { .usageCodex(.init(requestId: $0)) }
        }
        guard case .usageCodexResult(let result) = try Self.usageReply(reply) else { throw HostServiceError.unexpectedResponse }
        return result
    }

    /// Claude Code 的方案用量(`usage.claude`)。
    public func claudeUsage() async throws -> HostServiceProtocol.UsageClaudeResult {
        try await requireHostService(.planUsage)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.sendKeepingErrors { .usageClaude(.init(requestId: $0)) }
        }
        guard case .usageClaudeResult(let result) = try Self.usageReply(reply) else { throw HostServiceError.unexpectedResponse }
        return result
    }

    /// 各 Claude session 最近一次回報的 context 用量(`usage.session_context`;1–50 個 session)。
    public func sessionContexts(sessionIDs: [String]) async throws -> [HostServiceProtocol.SessionContext] {
        try await requireHostService(.sessionContext)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.sendKeepingErrors { .usageSessionContext(.init(requestId: $0, sessionIds: sessionIDs)) }
        }
        guard case .usageSessionContextResult(let result) = try Self.usageReply(reply) else { throw HostServiceError.unexpectedResponse }
        return result.sessions
    }

    /// 用量擷取(Claude status line 包裝)的安裝狀態(`claude_usage.status`)。
    public func claudeUsageStatus() async throws -> ClaudeUsageSetupStatus {
        try await claudeUsageSetup { .claudeUsageStatus(.init(requestId: $0)) }
    }

    /// 安裝用量擷取(`claude_usage.install`;呼叫端先取得使用者同意)。
    public func installClaudeUsage() async throws -> ClaudeUsageSetupStatus {
        try await claudeUsageSetup { .claudeUsageInstall(.init(requestId: $0)) }
    }

    /// 還原用量擷取(`claude_usage.remove`;SSH 或主機服務裝的都能還原)。
    public func removeClaudeUsage() async throws -> ClaudeUsageSetupStatus {
        try await claudeUsageSetup { .claudeUsageRemove(.init(requestId: $0)) }
    }

    /// 列出主機上一個資料夾的子資料夾名稱(`directory.list`;`path` 要是絕對路徑,`~` 先以 `homeDirectory()` 換掉)。
    public func listDirectory(path: String) async throws -> HostServiceProtocol.DirectoryListResult {
        try await requireHostService(.directoryBrowsing)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.sendKeepingErrors { .directoryList(.init(requestId: $0, path: path)) }
        }
        if case .errorMessage(let message) = reply { throw Self.directoryError(for: message) }
        guard case .directoryListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result
    }

    private func claudeUsageSetup(
        _ make: @escaping @Sendable (String) -> HostServiceProtocol.ClientMessage
    ) async throws -> ClaudeUsageSetupStatus {
        try await requireHostService(.claudeUsageSetup)
        let reply = try await withDeadline(HostCommandDeadline.standard) { try await self.sendKeepingErrors(make) }
        switch try Self.usageReply(reply) {
        case .claudeUsageStatusResult(let result):
            return ClaudeUsageSetupStatus(installed: result.installed, wrapperActive: result.wrapperActive, claudeFound: result.claudeFound)
        case .claudeUsageInstallResult(let result):
            return ClaudeUsageSetupStatus(installed: result.installed, wrapperActive: result.wrapperActive, claudeFound: result.claudeFound)
        case .claudeUsageRemoveResult(let result):
            return ClaudeUsageSetupStatus(installed: result.installed, wrapperActive: result.wrapperActive, claudeFound: result.claudeFound)
        default:
            throw HostServiceError.unexpectedResponse
        }
    }

    /// 錯誤訊息換成 `PlanUsageError`(其餘走共用對應);其他訊息原樣回傳。
    private static func usageReply(_ reply: HostServiceProtocol.ServerMessage) throws -> HostServiceProtocol.ServerMessage {
        guard case .errorMessage(let message) = reply else { return reply }
        throw usageError(for: message)
    }

    static func usageError(for message: HostServiceProtocol.ErrorMessage) -> any Error {
        switch message.code {
        case .codexNotFound: PlanUsageError.codexNotFound
        case .codexNotSignedIn: PlanUsageError.codexNotSignedIn
        case .codexFailed: PlanUsageError.codexFailed(message.message)
        case .claudeNotFound: PlanUsageError.claudeNotFound
        case .claudeSettingsNotJson: PlanUsageError.claudeSettingsNotJSON
        case .hostWriteFailed: PlanUsageError.hostWriteFailed(message.message)
        default: error(for: message)
        }
    }

    static func directoryError(for message: HostServiceProtocol.ErrorMessage) -> any Error {
        switch message.code {
        case .directoryNotFound: DirectoryListError.notFound
        case .directoryNotAllowed: DirectoryListError.notAllowed
        case .directoryUnreadable: DirectoryListError.unreadable
        default: error(for: message)
        }
    }
}

/// 用量擷取(Claude status line 包裝)在主機上的狀態。
public struct ClaudeUsageSetupStatus: Sendable, Equatable {
    /// 有安裝紀錄。
    public var installed: Bool
    /// settings.json 的 status line 現在是 Purrdr 的包裝(使用者安裝後自己換掉就是 `false`)。
    public var wrapperActive: Bool
    /// Claude Code 的設定資料夾存在(不存在時不能安裝)。
    public var claudeFound: Bool

    public init(installed: Bool, wrapperActive: Bool, claudeFound: Bool) {
        self.installed = installed
        self.wrapperActive = wrapperActive
        self.claudeFound = claudeFound
    }
}

/// 各 session 的 status line 狀態(#388):`usage.session_context`(主機服務 0.12.0 起;更舊的丟 `hostServiceUpdateRequired`,
/// 呼叫端退回對話紀錄算法)。協定只帶 context 用量,模型與 effort 沒有。
extension HTTPSHostConnection: ClaudeSessionStatusReading {
    public func sessionStatuses(sessionIDs: [String]) async throws -> [String: ClaudeSessionStatus] {
        let ids = Array(Set(sessionIDs.filter(ClaudeSessionStatus.isValidSessionID)).prefix(50))
        guard !ids.isEmpty else { return [:] }
        var result: [String: ClaudeSessionStatus] = [:]
        for context in try await sessionContexts(sessionIDs: ids) {
            result[context.sessionId] = ClaudeSessionStatus(
                sessionID: context.sessionId, capturedAt: ISO8601DateFormatter().date(from: context.capturedAt),
                contextPercent: context.usedPercentage, contextWindowSize: context.contextWindowSize)
        }
        return result
    }
}

extension HTTPSHostConnection: DirectoryBrowsing {}
