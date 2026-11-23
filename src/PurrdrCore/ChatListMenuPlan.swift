import Foundation

/// 聊天列表長按選單的項目(與舊列表的 SwiftUI contextMenu 相同)。
public enum ChatListMenuItem: Sendable, Equatable {
    case details
    case copyPath
    case copyContent
    case share
    case copyOutput
    case copyCommand
    case cancelSending
}

/// 哪一種列、帶哪些事實,決定選單有哪些項目。
public enum ChatListMenuKind: Sendable, Equatable {
    case none
    case file(hasCopyableContent: Bool, hasShareableFile: Bool)
    case image
    case shell(hasCopyableOutput: Bool)
    /// 離線佇列裡的訊息:還能取消(沒送出的問題訊息有自己的按鈕)才有選單。
    case queuedPrompt(canCancel: Bool)
}

/// 依列種類排出選單項目;空陣列表示這一列沒有選單(留給文字選取)。
public enum ChatListMenuPlan {
    public static func items(for kind: ChatListMenuKind) -> [ChatListMenuItem] {
        switch kind {
        case .none:
            return []
        case .file(let hasCopyableContent, let hasShareableFile):
            var items: [ChatListMenuItem] = [.details, .copyPath]
            if hasCopyableContent { items.append(.copyContent) }
            if hasShareableFile { items.append(.share) }
            return items
        case .image:
            return [.copyPath]
        case .shell(let hasCopyableOutput):
            return hasCopyableOutput ? [.copyOutput, .copyCommand] : [.copyCommand]
        case .queuedPrompt(let canCancel):
            return canCancel ? [.cancelSending] : []
        }
    }
}

/// 追蹤選單開著與否:只在狀態改變時回報,UIKit 重複的回呼忽略。
public struct ChatListMenuTracker: Sendable {
    public private(set) var isOpen = false

    public init() {}

    /// 狀態有改變時回傳新狀態,沒改變回傳 `nil`。
    public mutating func menuDidChange(isOpen newValue: Bool) -> Bool? {
        guard newValue != isOpen else { return nil }
        isOpen = newValue
        return newValue
    }
}
