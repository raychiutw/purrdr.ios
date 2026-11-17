import Foundation
import Testing

/// 承載白字的紅色填色一律用紅底角色(#70):tint 是紅字角色，深色模式白字對它不到 4.5:1。
@Suite("紅底用法")
struct BrandFillUsageTests {
    /// 把 tint／`AccentColor` 當成白字底色的寫法。prominent 按鈕樣式以 tint 為底，只能經 `.filledProminent` 系列套用。
    static let forbiddenPatterns = [
        "Color.accentColor", ".fill(.tint)", ".background(.tint", "(.borderedProminent)", "(.glassProminent)",
    ]
    /// 定義 `.filledProminent` 系列的檔案，裡面可以用系統 prominent 樣式。
    static let prominentStyleFile = "FilledProminentButtonStyle.swift"

    @Test("畫面不以 tint 或 AccentColor 當白字的填色")
    func screensUseBrandFillForWhiteText() throws {
        let featuresFolder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        let enumerator = try #require(FileManager.default.enumerator(at: featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var scannedFileCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            scannedFileCount += 1
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for (lineIndex, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for pattern in Self.forbiddenPatterns where line.contains(pattern) {
                    let isStyleDefinition = fileURL.lastPathComponent == Self.prominentStyleFile && pattern.hasSuffix("Prominent)")
                    if !isStyleDefinition {
                        violations.append("\(fileURL.lastPathComponent):\(lineIndex + 1) \(pattern)")
                    }
                }
            }
        }
        #expect(scannedFileCount > 10, "找不到 src/PurrdrFeatures 的原始碼")
        #expect(violations.isEmpty, "改用 .brandFill／.hostFill／.filledProminent:\n\(violations.joined(separator: "\n"))")
    }
}
