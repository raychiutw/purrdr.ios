#if os(iOS)
import Foundation
import PurrdrCore
import UIKit

/// 長按選單的一個項目:`perform` 做事;分享改由列表用系統分享面板呈現(帶 `shareURL`)。
struct ChatListMenuEntry {
    let item: ChatListMenuItem
    var shareURL: URL?
    var perform: @MainActor () -> Void = {}
}

extension ChatListMenuItem {
    /// 一個項目在選單上的樣子(標題字串與 SwiftUI 版 contextMenu 共用 catalog 的 key)。
    struct Presentation {
        let title: String
        let symbolName: String
        var isDestructive = false
    }

    /// 所有項目的標題、圖示與破壞性,一張對照表。
    var presentation: Presentation {
        switch self {
        case .details: Presentation(title: String(localized: "Details"), symbolName: "info.circle")
        case .copyPath: Presentation(title: String(localized: "Copy Path"), symbolName: Self.copySymbolName)
        case .copyContent: Presentation(title: String(localized: "Copy Content"), symbolName: Self.copySymbolName)
        case .share: Presentation(title: String(localized: "Share"), symbolName: "square.and.arrow.up")
        case .copyOutput: Presentation(title: String(localized: "Copy Output"), symbolName: Self.copySymbolName)
        case .copyCommand: Presentation(title: String(localized: "Copy Command"), symbolName: Self.copySymbolName)
        case .cancelSending: Presentation(title: String(localized: "Cancel Sending"), symbolName: "xmark", isDestructive: true)
        }
    }

    private static let copySymbolName = "document.on.document"
}
#endif
