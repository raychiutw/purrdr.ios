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

    /// 系統背景的 RGB 值(對比測試的背景,不是 app 自己指定的底色)。
    private static let surfaceHexes = ["1C1C1E", "2C2C2E", "3A3A3C", "242426", "363638", "444446"]

    @Test("沒有寫死的底色色碼:系統背景值(#1C1C1E 等)與 AppSurface.dark* 都不在程式碼裡(0x 寫法、字串 #RRGGBB、三段 red/green/blue)")
    func noHardCodedSurfaceHex() throws {
        let sources = try ChatColorUsageTests.featureSources()
        let channels = Self.surfaceHexes.map { hex in
            let parts = stride(from: 0, to: 6, by: 2).map { hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)] }
            return "0x\(parts[0])\\s*,\\s*(?:green:\\s*)?0x\(parts[1])\\s*,\\s*(?:blue:\\s*)?0x\(parts[2])"
        }
        let pattern = "(?i)0x(?:\(Self.surfaceHexes.joined(separator: "|")))\\b|\"#(?:\(Self.surfaceHexes.joined(separator: "|")))\"|AppSurface\\.dark|" + channels.joined(separator: "|")
        let found = try Self.matches(pattern, in: sources)
        #expect(found.isEmpty, "底色用系統語意色:\n\(found.joined(separator: "\n"))")
    }

    /// 取出 `.background`／`.listRowBackground`／`.containerBackground`／`.fill` 後面的括號或大括號內容(跨行、巢狀都算)。
    static func modifierBodies(in text: String) -> [(offset: Int, body: String)] {
        let names = [".background", ".listRowBackground", ".containerBackground", ".fill"]
        let characters = Array(text)
        var result: [(Int, String)] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == ".", let name = names.first(where: { name in
                let chars = Array(name)
                return index + chars.count <= characters.count && Array(characters[index..<index + chars.count]) == chars
            }) else { index += 1; continue }
            var cursor = index + name.count
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "(" || characters[cursor] == "{" else { index += 1; continue }
            var depth = 0
            var end = cursor
            while end < characters.count {
                if "({[".contains(characters[end]) { depth += 1 }
                if ")}]".contains(characters[end]) { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            result.append((index, String(characters[cursor..<min(end + 1, characters.count)])))
            index += name.count
        }
        return result
    }

    @Test("畫面的 .background／.listRowBackground／.fill 不用 RGB／十六進位自訂色(含跨行寫法)")
    func backgroundsDoNotUseLiteralColors() throws {
        let sources = try ChatColorUsageTests.featureSources().filter { $0.name != "PaneTerminalView.swift" }
        let literal = try Regex(##"Color\(\s*(?:\.sRGB,\s*)?red|Color\(hex|UIColor\(red|ThemeColor\(|0x[0-9A-Fa-f]{6}|"#[0-9A-Fa-f]{6}""##)
        var found: [String] = []
        for source in sources {
            let text = Self.codeLines(source).map { String($0.1) }.joined(separator: "\n")
            for (offset, body) in Self.modifierBodies(in: text) where body.contains(literal) {
                let line = text.prefix(offset).filter { $0 == "\n" }.count + 1
                found.append("\(source.name):約第 \(line) 行(註解行已略過)")
            }
        }
        #expect(found.isEmpty, "底色用 AppSurface 或系統語意色:\n\(found.joined(separator: "\n"))")
    }

    @Test("偵測器本身:跨行的 .background 與 .fill 抓得到自訂色")
    func modifierScannerFindsMultilineLiterals() throws {
        let text = "view\n    .background {\n        Color(red: 0.1, green: 0.2, blue: 0.3)\n    }\n    .background(Color.accentColor)"
        let bodies = Self.modifierBodies(in: text).map(\.body)
        #expect(bodies.count == 2)
        #expect(bodies[0].contains("Color(red"))
        #expect(!bodies[1].contains("Color(red"))
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
