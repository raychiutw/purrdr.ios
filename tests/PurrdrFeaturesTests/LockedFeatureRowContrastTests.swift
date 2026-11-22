import Foundation
import Testing

/// 沒有 Plus 時鎖定的功能列(#409):列仍可點,文字對比要 ≥ 4.5:1。
///
/// 對比由 `AccessibleColorsTests` 驗證 `secondaryText` 這組顏色;這裡守門「鎖定列只用它」——
/// 不能為了表現鎖定而把整列 `.disabled`、降低不透明度或改用系統 `.secondary`／`.tertiary`(對比不足)。
@Suite("鎖定功能列的對比")
struct LockedFeatureRowContrastTests {
    static func lockedRowSource() throws -> String {
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures/PlusCardView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "struct LockedFeatureRow"))
        let end = try #require(source.range(of: "extension FeatureLockReason"))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("鎖定列的說明文字用 secondaryText,不降低不透明度、不停用整列")
    func lockedRowKeepsReadableText() throws {
        let source = try Self.lockedRowSource()

        #expect(source.contains(".foregroundStyle(.secondaryText)"), "鎖定列的說明文字沒有用 secondaryText")
        for forbidden in [".opacity(", ".disabled(", ".foregroundStyle(.secondary)", ".foregroundStyle(.tertiary)", ".foregroundColor("] {
            #expect(!source.contains(forbidden), "鎖定列不可用 \(forbidden)(對比不足或列不能點)")
        }
    }
}
