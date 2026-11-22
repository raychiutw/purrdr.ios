import Foundation
import Testing

/// 聊天畫面色彩(#240,HIG 盤點 §16 第 10～13 項):錯誤以系統紅圖示表達、內容層底用系統語意色、使用者泡泡中性、工具紀錄標題不染主色。
@Suite("聊天畫面色彩用法")
struct ChatColorUsageTests {
    struct SourceFile {
        var name: String
        var lines: [Substring]
    }

    static func featureSources() throws -> [SourceFile] {
        let featuresFolder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        let enumerator = try #require(FileManager.default.enumerator(at: featuresFolder, includingPropertiesForKeys: nil))
        var sources: [SourceFile] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            sources.append(SourceFile(name: fileURL.lastPathComponent, lines: text.split(separator: "\n", omittingEmptySubsequences: false)))
        }
        #expect(sources.count > 10, "找不到 src/PurrdrFeatures 的原始碼")
        return sources
    }

    /// `struct <name>` 起到下一個頂層宣告前的程式碼。
    static func declaration(_ name: String, in sources: [SourceFile]) throws -> [Substring] {
        for source in sources {
            guard let start = source.lines.firstIndex(where: { $0.hasPrefix("struct \(name)") }) else { continue }
            let rest = source.lines[(start + 1)...]
            let end = rest.firstIndex(where: { $0.hasPrefix("struct ") || $0.hasPrefix("extension ") || $0.hasPrefix("private struct ") })
                ?? source.lines.endIndex
            return Array(source.lines[start..<end])
        }
        Issue.record("找不到 struct \(name)")
        return []
    }

    static func violations(of pattern: String, in sources: [SourceFile]) -> [String] {
        sources.flatMap { source in
            source.lines.enumerated().compactMap { index, line in
                line.contains(pattern) ? "\(source.name):\(index + 1)" : nil
            }
        }
    }

    @Test("錯誤不用紅色文字：沒有錯誤文字色 token,錯誤用主要色／次要文字色加系統紅圖示")
    func noErrorTextColor() throws {
        let sources = try Self.featureSources()
        let found = Self.violations(of: "errorText", in: sources)
        #expect(found.isEmpty, "改用 ErrorLabel 或 secondaryText:\n\(found.joined(separator: "\n"))")
    }

    /// 語意色只用系統紅、系統橙(ADR-0011);成功與勾選用主色。
    @Test("不用系統綠：成功與勾選用主色 tint")
    func noSystemGreen() throws {
        let sources = try Self.featureSources()
        let found = ["(.green)", "Color.green"].flatMap { Self.violations(of: $0, in: sources) }
        #expect(found.isEmpty, "改用 .tint:\n\(found.joined(separator: "\n"))")
    }

    /// skill／slash 指令名稱、連結與輸入框的綠色都是主色(tint;#329),不另設綠色票、不用 UIKit 系統綠。
    @Test("指令與輸入框不用系統綠：沒有 skillName 色票、沒有 systemGreen")
    func noSystemGreenForCommands() throws {
        let sources = try Self.featureSources()
        let found = ["skillName", "systemGreen", "systemMint", "systemTeal"].flatMap { Self.violations(of: $0, in: sources) }
        #expect(found.isEmpty, "指令名稱與輸入框元素改用主色 tint:\n\(found.joined(separator: "\n"))")
    }

    /// 錯誤圖示只在 `ErrorLabel`、subagent 狀態圖示(只有圖示、念狀態名)與用量條的偏高警示三角(#389,不是錯誤,依級距上色)。
    @Test("錯誤訊息不自組 Label,一律用 ErrorLabel")
    func errorsUseErrorLabel() throws {
        let allowed: Set<String> = ["ErrorLabel.swift", "DelegationViews.swift", "UsageSectionView.swift"]
        let sources = try Self.featureSources().filter { !allowed.contains($0.name) }
        let found = Self.violations(of: "exclamationmark.triangle.fill", in: sources)
        #expect(found.isEmpty, "改用 ErrorLabel:\n\(found.joined(separator: "\n"))")
    }

    @Test("內容層底色用系統語意色，不拿次要文字色當底")
    func contentBackgroundsUseSystemColors() throws {
        let sources = try Self.featureSources()
        let found = Self.violations(of: "Color.secondary.opacity(", in: sources)
        #expect(found.isEmpty, "改用 .background.secondary 或 .fill.tertiary:\n\(found.joined(separator: "\n"))")
    }

    /// 已確認的使用者泡泡與還沒確認的回音外觀相同。
    @Test("使用者泡泡與回音用中性填色與主要色文字，不用主色填色", arguments: ["UserBubbleView", "EchoBubbleView"])
    func userBubbleIsNeutral(view: String) throws {
        let sources = try Self.featureSources()
        let bubble = try Self.declaration(view, in: sources)
        let prominent = bubble.filter { $0.contains("hostFill") || $0.contains("prominentFill") || $0.contains(".tint") }
        #expect(prominent.isEmpty, "\(view) 不該用主色:\n\(prominent.joined(separator: "\n"))")
        #expect(bubble.contains { $0.contains(".userBubbleFill(") }, "\(view) 沒有用 userBubbleFill")
        let fill = sources.flatMap(\.lines).drop { !$0.contains("func userBubbleFill(") }.prefix(4)
        #expect(fill.contains { $0.contains(".fill.secondary") && $0.contains("foregroundStyle(.primary)") }, "userBubbleFill 不是系統次要填色加主要色文字")
    }

    /// `DisclosureGroup` 的 label 是按鈕，沒指定顏色會被 tint 染成主色。
    @Test("工具紀錄的 Thinking 與工具名稱指定主要色，不被染成主色")
    func toolStepTitlesArePrimary() throws {
        let step = try Self.declaration("ToolStepView", in: try Self.featureSources())
        for title in [#"Label("Thinking""#, "Text(call.name)"] {
            let index = try #require(step.firstIndex { $0.contains(title) }, "找不到 \(title)")
            let following = step[(index + 1)..<min(index + 4, step.endIndex)]
            #expect(following.contains { $0.contains(".foregroundStyle(Color.primary)") }, "\(title) 沒有指定主要色")
        }
    }

    /// 停止列(#220)併入狀態色對照表：成功、警告不另設文字色。
    @Test("沒有成功、警告文字色 token:狀態只上在符號，文字用主要色")
    func noStatusTextColors() throws {
        let sources = try Self.featureSources()
        let found = ["successText", "warningText"].flatMap { Self.violations(of: $0, in: sources) }
        #expect(found.isEmpty, "改用 StatusTone 的符號色:\n\(found.joined(separator: "\n"))")
    }

    @Test("停止列結果：符號用 StatusTone,文字是主要色")
    func stopBarResultUsesStatusTone() throws {
        let sources = try Self.featureSources()
        let stopBar = try #require(sources.first { $0.name == "StopBar.swift" })
        #expect(stopBar.lines.contains { $0.contains(".foregroundStyle(phase.tone.style)") }, "結果符號沒有用 StatusTone")
        #expect(stopBar.lines.contains { $0.contains(".foregroundStyle(Color.primary)") }, "結果文字沒有指定主要色")
    }
}
