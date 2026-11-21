import Foundation
import Testing

/// 導覽入口旁不放數字徽章(#322,DESIGN.md「工具列」):「完成」與其他工具列按鈕旁的數字讓人看不懂，
/// 「需要你」改由 Agent 列表的分組與狀態圖示呈現。掃描畫面程式碼的工具列項目，裡面不能有徽章。
@Suite("導覽入口的數字徽章")
struct NavigationBadgeUsageTests {
    /// 徽章：自訂的 `…Badge(` 元件或 SwiftUI 的 `.badge(`。
    static func isBadge(_ line: Substring) -> Bool {
        line.contains(/[A-Za-z]Badge\(/) || line.contains(".badge(")
    }

    @Test("工具列項目(含「完成」)裡沒有數字徽章")
    func toolbarItemsHaveNoBadge() throws {
        let featuresFolder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        let enumerator = try #require(FileManager.default.enumerator(at: featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var scannedFileCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            scannedFileCount += 1
            let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("ToolbarItem(") || line.contains("ToolbarItemGroup(") {
                let following = lines[index..<min(index + 12, lines.count)]
                if following.contains(where: Self.isBadge) {
                    violations.append("\(fileURL.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(scannedFileCount > 10, "找不到 src/PurrdrFeatures 的原始碼")
        #expect(violations.isEmpty, "工具列項目裡有數字徽章:\n\(violations.joined(separator: "\n"))")
    }
}
