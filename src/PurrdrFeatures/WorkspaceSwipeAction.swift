/// 聊天列的滑動動作與配色(#241):釘選主色、靜音與 Workspace 灰、關閉系統紅。
enum WorkspaceSwipeAction: CaseIterable, Sendable {
    case pin, mute, workspace, close

    /// 滑動鈕可用的顏色。
    enum Tint: Hashable, Sendable { case accent, gray, red }

    var tint: Tint {
        switch self {
        case .pin: .accent
        case .mute, .workspace: .gray
        case .close: .red
        }
    }
}
