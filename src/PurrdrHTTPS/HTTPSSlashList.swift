import Foundation
import PurrdrCore

/// HTTPS 主機的 Claude slash 清單(#733、主機服務 0.17.0 的 `slash.list`)。
///
/// 主機服務只回使用者層與已啟用 plugin 的項目;內建指令由 app 合併進來(優先序最高,F9.1)。
/// 專案層(cwd)的項目主機服務不回,HTTPS 主機的選單因此沒有專案層分組。
/// 版本不足(0.17.0 以前)、請求失敗或逾時:退回只有內建指令、標示不完整,與沒有探索器時相同。
extension HTTPSHostConnection: SlashDiscovering {
    public func catalog(cwd: String?, transcriptPath: String?) async -> SlashCatalog {
        let builtIn = ClaudeBuiltinCommands.all.map { (source: SlashSource.builtIn, command: $0) }
        do {
            let result = try await slashList()
            let listed = result.commands.map { entry -> (source: SlashSource, command: SlashCommand) in
                let source: SlashSource = entry.source == "plugin" ? .plugin(entry.plugin ?? "") : .user
                return (source, SlashCommand(name: entry.name, argumentHint: entry.argumentHint, summary: entry.summary))
            }
            return SlashCatalog.merged(builtIn + listed, isComplete: !result.truncated)
        } catch {
            return SlashCatalog.merged(builtIn, isComplete: false)
        }
    }

    /// 主機上的 slash 清單(`slash.list`;唯讀)。
    public func slashList() async throws -> HostServiceProtocol.SlashListResult {
        try await requireHostService(.slashList)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.sendKeepingErrors { .slashList(.init(requestId: $0)) }
        }
        if case .errorMessage(let message) = reply { throw Self.error(for: message) }
        guard case .slashListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result
    }
}
