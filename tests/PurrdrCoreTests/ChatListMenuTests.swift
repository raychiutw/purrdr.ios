import Foundation
import PurrdrCore
import Testing

/// 聊天列表長按選單的項目規則與開關追蹤(#488):項目與舊列表(SwiftUI contextMenu)相同。
@Suite("聊天列表:長按選單")
struct ChatListMenuTests {
    @Test("檔案卡片:詳細、複製路徑;有內容才有複製內容;下載好了才有分享")
    func fileCardItems() {
        #expect(ChatListMenuPlan.items(for: .file(hasCopyableContent: false, hasShareableFile: false)) == [.details, .copyPath])
        #expect(ChatListMenuPlan.items(for: .file(hasCopyableContent: true, hasShareableFile: false)) == [.details, .copyPath, .copyContent])
        #expect(
            ChatListMenuPlan.items(for: .file(hasCopyableContent: true, hasShareableFile: true))
                == [.details, .copyPath, .copyContent, .share])
        #expect(ChatListMenuPlan.items(for: .file(hasCopyableContent: false, hasShareableFile: true)) == [.details, .copyPath, .share])
    }

    @Test("圖片卡片只有複製路徑")
    func imageCardItems() {
        #expect(ChatListMenuPlan.items(for: .image) == [.copyPath])
    }

    @Test("shell 區塊:有輸出才有複製輸出,永遠有複製指令")
    func shellItems() {
        #expect(ChatListMenuPlan.items(for: .shell(hasCopyableOutput: true)) == [.copyOutput, .copyCommand])
        #expect(ChatListMenuPlan.items(for: .shell(hasCopyableOutput: false)) == [.copyCommand])
    }

    @Test("離線佇列的訊息:能取消才有取消送出")
    func queuedPromptItems() {
        #expect(ChatListMenuPlan.items(for: .queuedPrompt(canCancel: true)) == [.cancelSending])
        #expect(ChatListMenuPlan.items(for: .queuedPrompt(canCancel: false)).isEmpty)
    }

    @Test("沒有選單的列(文字訊息等)回空,留給文字選取")
    func plainRowHasNoItems() {
        #expect(ChatListMenuPlan.items(for: .none).isEmpty)
    }

    @Test("選單開關:只在狀態改變時回報,重複的回呼忽略")
    func trackerReportsChangesOnly() {
        var tracker = ChatListMenuTracker()
        #expect(!tracker.isOpen)
        #expect(tracker.menuDidChange(isOpen: false) == nil)
        #expect(tracker.menuDidChange(isOpen: true) == true)
        #expect(tracker.isOpen)
        #expect(tracker.menuDidChange(isOpen: true) == nil)
        #expect(tracker.menuDidChange(isOpen: false) == false)
        #expect(!tracker.isOpen)
    }
}
