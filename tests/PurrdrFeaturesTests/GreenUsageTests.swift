import Foundation
import Testing

/// 綠色統一為主色(#649,ADR-0011):app 自己畫的綠只有主色(翡翠綠)。
/// 終端機 ANSI、主機主題的綠是語意色,不在掃描範圍(它們在 PurrdrCore 的 XtermPalette／HostTheme 與 PaneTerminalView、HostThemeViews)。
@Suite("綠色只用主色")
struct GreenUsageTests {
    /// 不屬於 app 自繪色的檔案:終端機與主機主題(IMEIndicatorTint 只處理 RGB 通道)。
    private static let exempt: Set<String> = ["PaneTerminalView.swift", "HostThemeViews.swift", "IMEIndicatorTint.swift"]

    private static func scanned() throws -> [ChatColorUsageTests.SourceFile] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources = try ChatColorUsageTests.featureSources().filter { !exempt.contains($0.name) }
        let profile = root.appending(path: "src/PurrdrCore/AgentProfile.swift")
        let text = try String(contentsOf: profile, encoding: .utf8)
        sources.append(.init(name: "AgentProfile.swift", lines: text.split(separator: "\n", omittingEmptySubsequences: false)))
        return sources
    }

    private static func codeLines(_ source: ChatColorUsageTests.SourceFile) -> [(Int, String)] {
        source.lines.enumerated().compactMap { index, line in
            line.drop(while: { $0 == " " }).hasPrefix("//") ? nil : (index + 1, String(line))
        }
    }

    @Test("沒有系統綠、薄荷、青綠(.green／.mint／.teal、systemGreen…)")
    func noSystemGreens() throws {
        let expression = try Regex(#"(foregroundStyle|foregroundColor|tint|fill|stroke|background|accentColor)\(\s*\.(green|mint|teal)\b|Color\.(green|mint|teal)\b|\.system(Green|Mint|Teal)\b|\(\.(green|mint|teal)\)"#)
        let found = try Self.scanned().flatMap { source in
            Self.codeLines(source).filter { $0.1.contains(expression) }.map { "\(source.name):\($0.0)" }
        }
        #expect(found.isEmpty, "綠色一律用主色(Color.appAccent):\n\(found.joined(separator: "\n"))")
    }

    /// 綠色為主的色碼(g 比 r 高 20 以上、比 b 高 8 以上)只能是主色,或流量圖 Wi-Fi 的「主色同色相另一階」(#649)。
    @Test("沒有非主色的綠色色碼")
    func noOtherGreenHex() throws {
        let accent: Set<[Int]> = [[0x0B, 0x7A, 0x5C], [0x3C, 0xCF, 0x9E], [0x07, 0x5C, 0x45], [0x5D, 0xE0, 0xB3],
            [0x2E, 0x9C, 0x7A], [0x22, 0x9C, 0x77], [0x1F, 0x8A, 0x6B], [0x28, 0xA6, 0x7F],  // Wi-Fi 階(DataUsageColorsTests 驗對比)
        ]
        let triple = try Regex(#"(?:red:\s*)?0x([0-9A-Fa-f]{2}),\s*(?:green:\s*)?0x([0-9A-Fa-f]{2}),\s*(?:blue:\s*)?0x([0-9A-Fa-f]{2})"#)
        let hex = try Regex(#"#([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})\b"#)
        var found: [String] = []
        for source in try Self.scanned() {
            for (number, line) in Self.codeLines(source) {
                for expression in [triple, hex] {
                    for match in line.matches(of: expression) {
                        let values = (1...3).compactMap { match.output[$0].substring.flatMap { Int($0, radix: 16) } }
                        guard values.count == 3, !accent.contains(values) else { continue }
                        if values[1] > values[0] + 20, values[1] > values[2] + 8 {
                            found.append("\(source.name):\(number) \(line.trimmingCharacters(in: .whitespaces))")
                        }
                    }
                }
            }
        }
        #expect(found.isEmpty, "非主色的綠:\n\(found.joined(separator: "\n"))")
    }
}
