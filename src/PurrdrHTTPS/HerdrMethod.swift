import Foundation
import PurrdrCore

/// 需要版本門檻或特殊錯誤對應的 herdr method(method 字串只寫在這裡;`HTTPSTypedOperations` 的 `perform` 用它登記版本門檻)。
enum HerdrMethod: String {
    case agentPrompt = "agent.prompt"
    case workspaceCreate = "workspace.create"
    case workspaceRename = "workspace.rename"
    case tabRename = "tab.rename"
    case workspaceClose = "workspace.close"
    /// 主機服務 0.15.0 起(`HostServiceFeature.tabClose`)。
    case tabClose = "tab.close"
    /// 主機服務 0.15.0 起(`HostServiceFeature.tabCreate`)。
    case tabCreate = "tab.create"
    case worktreeCreate = "worktree.create"
    case agentStart = "agent.start"
    case sessionsList = "sessions.list"

    /// 這個 method 需要的主機服務功能(版本門檻);`nil` 是一開始就有的。
    var requiredFeature: HostServiceFeature? {
        switch self {
        case .workspaceCreate, .workspaceRename, .workspaceClose, .worktreeCreate, .agentStart: .workspaceOperations
        case .tabRename: .tabRename
        case .tabClose: .tabClose
        case .tabCreate: .tabCreate
        case .sessionsList: .sessionResume
        default: nil
        }
    }
}

extension HerdrMethod {
    /// agent.start 的啟動參數換成主機服務的權限模式(主機服務不收任意參數：只認得 Claude Code 的權限模式)。
    /// 設定檔的啟動參數(Codex 的 `--no-daemon`,#400)主機服務不收,也不能因它拒絕整個啟動;依那個種類的設定檔整組略過
    /// (只略過前綴那一組,使用者自己帶的同名參數不在其內),等主機服務支援再送。其他參數丟 `unsupported(method)`。
    static func permissionMode(kind: String, arguments original: [String], method: String) throws -> HostServiceProtocol.ClaudePermissionMode? {
        let launchArguments = AgentCatalog.profile(forHerdrName: kind).session.launchArguments
        var arguments = original
        if !launchArguments.isEmpty, arguments.starts(with: launchArguments) { arguments.removeFirst(launchArguments.count) }
        switch arguments {
        case []: return nil
        case let args where args.count == 2 && args[0] == "--permission-mode":
            guard let mode = HostServiceProtocol.ClaudePermissionMode(rawValue: args[1]) else { throw HostServiceError.unsupported(method) }
            return mode
        default: throw HostServiceError.unsupported(method)
        }
    }
}
