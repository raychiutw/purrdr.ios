import Foundation
import Testing

/// 選擇控制(#313,DESIGN.md「選擇控制」):選項一律像「設定」app 的勾選列上下攤開(`.pickerStyle(.inline)`),
/// 不用點開才看得到的下拉、分段，也不把選項切換藏進選單。例外只有數量沒有上限的主機選擇、頁面層級的 Agents／Spaces 切換，與使用者選定的權限模式膠囊長按選單(#306)。
@Suite("選擇控制用法")
struct SelectionControlUsageTests {
    /// 每個檔案可以有幾個不是 `.inline` 的 Picker(例外)。
    static let nonInlinePickerAllowance = [
        // 方案用量的主機選擇、左上角的主機篩選(主機數量沒有上限)。
        "PlanUsageView.swift": 1,
        "TopNavigationView.swift": 1,
    ]
    /// 可以把 Picker 放在選單裡的檔案：主機篩選與主機挑選鈕,以及左上角 Agents／Spaces 切換鈕的長按選單(#391,SpacesListView)。
    static let hostMenuFiles: Set = ["HostPickerViews.swift", "TopNavigationView.swift", "DataUsageView.swift", "SpacesListView.swift"]

    /// SwiftUI 的 `Picker(`(前面不接英文字母：`hostPicker(`、`photosPicker(` 不算)。
    static func isPicker(_ line: Substring) -> Bool {
        line.contains(/(^|[^A-Za-z])Picker\(/)
    }

    @Test("畫面的選項一律攤開成勾選列：只有例外可以用下拉或分段，選單裡只有主機選擇")
    func screensExpandOptions() throws {
        let featuresFolder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        let enumerator = try #require(FileManager.default.enumerator(at: featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var scannedFileCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            scannedFileCount += 1
            let name = fileURL.lastPathComponent
            let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            let pickers = lines.filter(Self.isPicker).count
            let inline = lines.filter { $0.contains(".pickerStyle(.inline)") }.count
            let allowed = Self.nonInlinePickerAllowance[name, default: 0]
            if pickers - inline > allowed {
                violations.append("\(name):\(pickers - inline) 個 Picker 不是 .inline(允許 \(allowed) 個)")
            }
            // 手繪的選擇列與卡片一律列尾打勾(同 `.inline` Picker),不用列前的實心／空心圓圈(含 Purrdr Plus 方案卡)。
            for (index, line) in lines.enumerated() where line.contains(#""checkmark.circle.fill" : "circle""#) {
                violations.append("\(name):\(index + 1) 選擇列用列前圓圈，改成列尾打勾")
            }
            guard !Self.hostMenuFiles.contains(name) else { continue }
            for (index, line) in lines.enumerated() where line.contains("Menu {") || line.contains(".contextMenu {") {
                let following = lines[(index + 1)..<min(index + 15, lines.count)]
                if following.contains(where: Self.isPicker) {
                    violations.append("\(name):\(index + 1) 選單裡有 Picker")
                }
            }
        }
        #expect(scannedFileCount > 10, "找不到 src/PurrdrFeatures 的原始碼")
        #expect(violations.isEmpty, "選項改用 .pickerStyle(.inline) 攤開，不放進選單:\n\(violations.joined(separator: "\n"))")
    }
}
