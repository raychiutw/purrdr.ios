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
    /// 選單上的標題(字串與 SwiftUI 版 contextMenu 共用 catalog 的 key)。
    var title: String {
        switch self {
        case .details: String(localized: "Details")
        case .copyPath: String(localized: "Copy Path")
        case .copyContent: String(localized: "Copy Content")
        case .share: String(localized: "Share")
        case .copyOutput: String(localized: "Copy Output")
        case .copyCommand: String(localized: "Copy Command")
        }
    }

    var symbolName: String {
        switch self {
        case .details: "info.circle"
        case .share: "square.and.arrow.up"
        case .copyPath, .copyContent, .copyOutput, .copyCommand: "document.on.document"
        }
    }
}
#endif
