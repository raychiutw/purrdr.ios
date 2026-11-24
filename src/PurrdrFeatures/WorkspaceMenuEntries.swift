/// 選單項目(#536):Tab 列長按選單與 Workspace 段落標題長按選單的項目清單由這裡一處決定,
/// 畫面照清單排,免得 Tab 選單又混進 Workspace 層級的動作。
enum WorkspaceMenuEntry: Equatable {
    case openInNewWindow
    case pin
    case mute
    case showLayout
    case renameTab
    case closeTab
    case newChatHere
    case renameWorkspace
    case newWorktree
    case closeWorkspace
}

enum WorkspaceMenuLevel {
    case tab(hasNewWindow: Bool, hasChats: Bool, hasTab: Bool)
    case workspace(canStartChat: Bool)

    var entries: [WorkspaceMenuEntry] {
        switch self {
        case .tab(let hasNewWindow, let hasChats, let hasTab):
            var result: [WorkspaceMenuEntry] = []
            if hasNewWindow { result.append(.openInNewWindow) }
            if hasChats { result += [.pin, .mute] }
            result.append(.showLayout)
            if hasTab { result += [.renameTab, .closeTab] }
            return result
        case .workspace(let canStartChat):
            // 「在此新增聊天」(#537)只在這台主機支援時出現(HTTPS 主機服務要 0.15.0 起才有 tab.create)。
            return (canStartChat ? [.newChatHere] : []) + [.renameWorkspace, .showLayout, .newWorktree, .closeWorkspace]
        }
    }
}
