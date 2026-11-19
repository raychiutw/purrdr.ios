import Foundation
import Testing

/// 承載字的主色填色一律經 `prominentFill`／`onProminentFill`(ADR-0011):深色模式主色上要用黑字，系統 prominent 樣式預設白字。
@Suite("主色填色用法")
struct ProminentFillUsageTests {
    /// 直接拿主色當底、繞過 `onProminentFill` 字色的寫法;`.accentColor` 也擋省略 `Color.` 的寫法(滑動鈕 `.tint(.accentColor)`)。
    static let forbiddenPatterns = [
        ".accentColor", ".fill(.tint)", ".background(.tint", "(.borderedProminent)", "(.glassProminent)",
    ]
    /// 定義 `prominentFill` 與 `.filledProminent` 系列的檔案。
    static let prominentStyleFile = "FilledProminentButtonStyle.swift"

    @Test("畫面不直接以 tint 或 AccentColor 當填色")
    func screensUseProminentFill() throws {
        let featuresFolder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        let enumerator = try #require(FileManager.default.enumerator(at: featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var scannedFileCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" && fileURL.lastPathComponent != Self.prominentStyleFile {
            scannedFileCount += 1
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for (lineIndex, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for pattern in Self.forbiddenPatterns where line.contains(pattern) {
                    violations.append("\(fileURL.lastPathComponent):\(lineIndex + 1) \(pattern)")
                }
            }
        }
        #expect(scannedFileCount > 10, "找不到 src/PurrdrFeatures 的原始碼")
        #expect(violations.isEmpty, "改用 .prominentFill／.onProminentFill／.hostFill／.filledProminent:\n\(violations.joined(separator: "\n"))")
    }
}
