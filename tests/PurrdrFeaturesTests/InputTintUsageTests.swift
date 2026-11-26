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

    @Test("UIKit 輸入元件的 tintColor 覆寫回傳系統文字色,不從主色推導")
    func uikitInputsUseLabelTint() throws {
        var overrides = 0
        var violations: [String] = []
        for (name, text) in try Self.sources() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("override var tintColor") {
                overrides += 1
                let body = lines[index..<min(index + 4, lines.count)].joined(separator: "\n")
                if !body.contains("UIColor.label") || body.contains("get { super.tintColor") || body.contains("indicatorTint") {
                    violations.append("\(name):\(index + 1)")
                }
            }
            if text.contains("indicatorTint") { violations.append("\(name) 仍有 indicatorTint") }
        }
        #expect(overrides == 2, "聊天輸入框與終端機輸入元件各一個 tintColor 覆寫")
        #expect(violations.isEmpty, "tint 改回傳 UIColor.label:\n\(violations.joined(separator: "\n"))")
    }

    @Test("用 SwiftUI 文字輸入元件的畫面檔都套 inputFieldTint")
    func swiftUIInputsApplyInputFieldTint() throws {
        let markers = ["TextField(", "SecureField(", "TextEditor("]
        var missing: [String] = []
        for (name, text) in try Self.sources() where name != "InputFieldTint.swift" {
            // 只掃真正的程式行(略過註解)。
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let used = code.filter { line in markers.contains { line.contains($0) } }.count
            let applied = code.filter { $0.contains(".inputFieldTint()") }.count
            if used > 0 && applied == 0 { missing.append(name) }
        }
        #expect(missing.isEmpty, "這些檔案有文字輸入元件卻沒有 .inputFieldTint():\n\(missing.joined(separator: "\n"))")
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
