import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// iPad 分欄的選取列是中性灰底(#238):文字維持主要色與次要文字色，不用主色底、不改白字。
@Suite("iPad 中性選取")
struct SelectionAppearanceTests {
    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    /// iOS `systemGray5` 的四值(Apple 系統色表):light／dark／各自高對比。
    static let systemGray5 = (
        light: ThemeColor(red: 0xE5, green: 0xE5, blue: 0xEA),
        dark: ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E),
        lightHighContrast: ThemeColor(red: 0xD8, green: 0xD8, blue: 0xDC),
        darkHighContrast: ThemeColor(red: 0x36, green: 0x36, blue: 0x38)
    )
    /// 主要文字(`label`):淺色黑、深色白。
    static let black = ThemeColor(red: 0x00, green: 0x00, blue: 0x00)
    static let white = ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)

    @Test("選取列的主要與次要文字對中性灰底 ≥ 4.5:1")
    func textOnSelectionMeetsHIG() {
        let secondary = AccessibleColors.secondaryText
        let cases: [(String, ThemeColor, ThemeColor)] = [
            ("淺色主要", Self.black, Self.systemGray5.light),
            ("深色主要", Self.white, Self.systemGray5.dark),
            ("淺色高對比主要", Self.black, Self.systemGray5.lightHighContrast),
            ("深色高對比主要", Self.white, Self.systemGray5.darkHighContrast),
            ("淺色次要", secondary.light, Self.systemGray5.light),
            ("深色次要", secondary.dark, Self.systemGray5.dark),
            ("淺色高對比次要", secondary.lightHighContrast, Self.systemGray5.lightHighContrast),
            ("深色高對比次要", secondary.darkHighContrast, Self.systemGray5.darkHighContrast),
        ]
        for (name, text, background) in cases {
            let ratio = text.contrastRatio(with: background)
            #expect(ratio >= 4.5, "\(name) \(text) 對 \(background) 只有 \(ratio)")
        }
    }

    @Test("選取列用系統中性灰底，不用主色填色")
    func selectionUsesNeutralFill() throws {
        let source = try String(contentsOf: Self.featuresFolder.appending(path: "AgentListView.swift"), encoding: .utf8)
        let modifier = try #require(source.range(of: "private struct SelectionFillModifier")).lowerBound
        let modifierSource = source[modifier...].prefix(1200)
        #expect(modifierSource.contains(".listRowBackground(isSelected ? Rectangle().fill(.neutralSelection)"))
        #expect(!modifierSource.contains("prominentFill"))
        #expect(!modifierSource.contains("onProminentFill"))
    }

    @Test("列不再依 backgroundProminence 改白字")
    func rowsHaveNoProminentTextBranch() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.featuresFolder, includingPropertiesForKeys: nil))
        var violations: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for (lineIndex, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("backgroundProminence") {
                violations.append("\(fileURL.lastPathComponent):\(lineIndex + 1)")
            }
        }
        #expect(violations.isEmpty, "選取列文字維持主要色與次要文字色:\n\(violations.joined(separator: "\n"))")
    }
}
