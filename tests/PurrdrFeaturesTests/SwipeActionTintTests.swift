@testable import PurrdrFeatures
import Testing

/// 聊天列滑動鈕的配色(#241、hig-audit 4.5):釘選主色、靜音與 Workspace 灰、關閉系統紅。
@Suite("滑動鈕配色")
struct SwipeActionTintTests {
    @Test("釘選用主色")
    func pinUsesAccent() {
        #expect(WorkspaceSwipeAction.pin.tint == .accent)
    }

    @Test("靜音與 Workspace 用灰")
    func muteAndWorkspaceUseGray() {
        #expect(WorkspaceSwipeAction.mute.tint == .gray)
        #expect(WorkspaceSwipeAction.workspace.tint == .gray)
    }

    @Test("關閉用系統紅")
    func closeUsesRed() {
        #expect(WorkspaceSwipeAction.close.tint == .red)
    }

    @Test("滑動鈕只用主色、灰、紅三種")
    func swipeTintsStayWithinThreeColors() {
        let tints = Set(WorkspaceSwipeAction.allCases.map(\.tint))

        #expect(tints.isSubset(of: [.accent, .gray, .red]))
    }
}
