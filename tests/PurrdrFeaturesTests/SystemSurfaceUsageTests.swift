import Foundation
import Testing

/// 底色與文字回到系統色(#646,取代 #379):原始碼不寫死底色色碼、不留 app 自訂的深色層次與 tab 選取色。
@Suite("系統底色用法")
struct SystemSurfaceUsageTests {
    /// 去掉整行註解的程式碼行(含行號)。
    private static func codeLines(_ source: ChatColorUsageTests.SourceFile) -> [(Int, Substring)] {
        source.lines.enumerated().compactMap { index, line in
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("//") ? nil : (index + 1, line)
        }
    }

    private static func matches(_ pattern: String, in sources: [ChatColorUsageTests.SourceFile]) throws -> [String] {
        let expression = try Regex(pattern)
        return sources.flatMap { source in
            codeLines(source).compactMap { number, line in
                line.contains(expression) ? "\(source.name):\(number)" : nil
            }
        }
    }

    @Test("沒有寫死的底色色碼:系統背景值(#1C1C1E 等)與 AppSurface.dark* 都不在程式碼裡")
    func noHardCodedSurfaceHex() throws {
        let sources = try ChatColorUsageTests.featureSources()
        let found = try Self.matches(#"(?i)0x(1C1C1E|2C2C2E|3A3A3C|242426|363638|444446)\b|AppSurface\.dark"#, in: sources)
        #expect(found.isEmpty, "底色用系統語意色:\n\(found.joined(separator: "\n"))")
    }

    @Test("畫面的 .background 不用 RGB／十六進位自訂色")
    func backgroundsDoNotUseLiteralColors() throws {
        let sources = try ChatColorUsageTests.featureSources().filter { $0.name != "PaneTerminalView.swift" }
        let found = try Self.matches(#"\.background\(.*(Color\(red|Color\(hex|UIColor\(red|0x[0-9A-Fa-f]{6})"#, in: sources)
        #expect(found.isEmpty, "底色用 AppSurface 或系統語意色:\n\(found.joined(separator: "\n"))")
    }

    @Test("AppSurface 沒有自己的深色分支,tab 選取沒有自訂色")
    func noCustomDarkBranchOrTabSelection() throws {
        let sources = try ChatColorUsageTests.featureSources()
        let surface = try #require(sources.first { $0.name == "AppSurface.swift" })
        let found = Self.codeLines(surface).filter { $0.1.contains("userInterfaceStyle") }
        #expect(found.isEmpty, "AppSurface 直接對應系統語意色,不依深淺色分支")
        let tab = try Self.matches("tabSelection", in: sources)
        #expect(tab.isEmpty, "tab 選取態交給系統以主色畫:\n\(tab.joined(separator: "\n"))")
    }
}
