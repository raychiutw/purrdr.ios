import Foundation
import Testing

/// 輸入元件的 tint 一律是系統文字色(#647、spec #645):鍵盤輸入法提示膠囊(聽寫、「國」)、游標與選取反白都跟著 tint,
/// 深色白底深字、淺色黑底淺字。不再把主色壓暗給膠囊用,也不讓輸入元件用主色。
@Suite("輸入元件 tint 用法")
struct InputTintUsageTests {
    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    static func sources() throws -> [(name: String, text: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: featuresFolder, includingPropertiesForKeys: nil))
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(result.count > 10, "找不到 src/PurrdrFeatures 的原始碼")
        return result
    }

    /// 一個 UIKit 輸入元件:檔案裡頂層宣告、繼承或遵循文字輸入型別的 class,與它的原始碼範圍(到下一個頂層 `}`)。
    private static var uikitInputDeclaration: Regex<(Substring, Substring, Substring)> { #/^(?:final )?class (\w+)\s*:[^{]*\b(UITextView|UITextField|UISearchTextField|UITextInput|UIKeyInput)\b/# }

    @Test("每個 UIKit 輸入元件的 tintColor 覆寫都回傳系統文字色,不從主色推導")
    func uikitInputsUseLabelTint() throws {
        var inputs: [String] = []
        var violations: [String] = []
        for (name, text) in try Self.sources() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                guard let match = line.firstMatch(of: Self.uikitInputDeclaration) else { continue }
                let end = lines[index...].firstIndex { $0 == "}" } ?? lines.endIndex
                let range = lines[index..<end]
                inputs.append("\(name):\(match.output.1)")
                guard let override = range.firstIndex(where: { $0.contains("override var tintColor") }) else {
                    violations.append("\(name):\(match.output.1) 沒有 tintColor 覆寫")
                    continue
                }
                let body = lines[override..<min(override + 4, lines.count)].joined(separator: "\n")
                if !body.contains("get { UIColor.label }") { violations.append("\(name):\(override + 1) getter 不是 UIColor.label") }
            }
            if text.contains("indicatorTint") { violations.append("\(name) 仍有 indicatorTint") }
        }
        #expect(inputs.count >= 2, "至少找得到聊天輸入框與終端機輸入元件(找到 \(inputs)),偵測規則失效")
        #expect(violations.isEmpty, "tint 改回傳 UIColor.label:\n\(violations.joined(separator: "\n"))")
    }

    @Test("每個 SwiftUI 文字輸入元件都各自套 inputFieldTint")
    func swiftUIInputsApplyInputFieldTint() throws {
        let marker = #/\b(?:TextField|SecureField|TextEditor)\(/#
        var found = 0
        var missing: [String] = []
        for (name, text) in try Self.sources() where name != "InputFieldTint.swift" {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let isCode = { (line: String) in !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for (index, line) in lines.enumerated() where isCode(line) && line.contains(marker) {
                found += 1
                // 往後看到下一個輸入元件(不含)為止,最多 8 行:這段修飾子裡要有 .inputFieldTint()。
                var window = lines[(index + 1)...].prefix(8)
                if let next = window.firstIndex(where: { isCode($0) && $0.contains(marker) }) { window = lines[(index + 1)..<next] }
                if !(line.contains(".inputFieldTint()") || window.contains { $0.contains(".inputFieldTint()") }) {
                    missing.append("\(name):\(index + 1)")
                }
            }
        }
        #expect(found >= 10, "找到的 SwiftUI 輸入元件數量不對(\(found)),偵測規則失效")
        #expect(missing.isEmpty, "這些輸入元件沒有 .inputFieldTint():\n\(missing.joined(separator: "\n"))")
    }

    @Test("搜尋欄(.searchable)的輸入框 tint 經 UISearchTextField 外觀代理設成系統文字色")
    func searchFieldUsesLabelTint() throws {
        let sources = try Self.sources()
        #expect(sources.contains { $0.text.contains(".searchable(") }, "預期有畫面用 .searchable")
        let install = sources.first { $0.name == "InputFieldTint.swift" }?.text ?? ""
        #expect(install.contains("UISearchTextField.appearance().tintColor = UIColor.label"))
    }

    @Test("輸入元件 tint 不用主色")
    func inputTintIsNotAccent() throws {
        for (name, text) in try Self.sources() {
            for line in text.split(separator: "\n") where line.contains("inputFieldTint") && (line.contains("accent") || line.contains("ProminentFill")) {
                Issue.record("\(name): \(line)")
            }
        }
    }
}
