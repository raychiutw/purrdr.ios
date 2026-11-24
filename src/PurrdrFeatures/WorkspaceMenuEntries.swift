/// 選單項目(#536):Tab 列長按選單與 Workspace 段落標題長按選單的項目清單由這裡一處決定,
/// 畫面照清單排,免得 Tab 選單又混進 Workspace 層級的動作。
enum WorkspaceMenuEntry: Equatable {
    case openInNewWindow
    case pin
    case mute
    case showLayout
    case renameTab
    case closeTab
    case renameWorkspace
    case newWorktree
    case closeWorkspace
}

enum WorkspaceMenuLevel {
    case tab(hasNewWindow: Bool, hasChats: Bool, hasTab: Bool)
    case workspace

    var entries: [WorkspaceMenuEntry] {
        switch self {
        case .tab(let hasNewWindow, let hasChats, let hasTab):
            var result: [WorkspaceMenuEntry] = []
            if hasNewWindow { result.append(.openInNewWindow) }
            if hasChats { result += [.pin, .mute] }
            result.append(.showLayout)
            if hasTab { result += [.renameTab, .closeTab] }
            return result
        case .workspace:
            return [.renameWorkspace, .showLayout, .newWorktree, .closeWorkspace]
        }
    }
}
