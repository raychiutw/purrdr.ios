import Foundation
import Testing

/// HIG 盤點(研究報告 §16 第 3 項)列出的可點列與卡片都要有按壓回饋(#234)。
@Suite("按壓回饋的套用")
struct PressFeedbackUsageTests {
    /// 盤點清單：Spaces 群組標頭與大標題選單、方案卡片、Google 鈕、建議提示詞、slash 選單、註記列、縮圖、側欄主機列。
    static let inventoriedFiles = [
        "SpacesListView.swift", "PlusView.swift", "MemberView.swift", "PromptSuggestionView.swift",
        "SlashMenuView.swift", "YouShouldKnowViews.swift", "ComposerImageViews.swift", "WindowViews.swift",
    ]

    @Test("盤點的畫面用共用按壓樣式，不留沒有按壓態的 .plain", arguments: inventoriedFiles)
    func inventoriedScreenUsesPressableStyle(fileName: String) throws {
        let fileURL = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures/\(fileName)")
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!source.contains(".buttonStyle(.plain)"), "\(fileName) 還有 .buttonStyle(.plain)")
        #expect(source.contains(".buttonStyle(.pressable"), "\(fileName) 沒有套用共用按壓樣式")
    }
}
