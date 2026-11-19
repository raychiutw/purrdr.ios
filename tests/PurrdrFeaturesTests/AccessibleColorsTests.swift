import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 承載文字的自訂顏色對比(#35;HIG 20.2:文字對比 ≥ 4.5:1,Increase Contrast 時 ≥ 7:1)。
@Suite("無障礙配色")
struct AccessibleColorsTests {
    /// 次要文字可能落在的背景(固定值，取自 iOS 系統色):
    /// 淺色：主要背景 `systemBackground`／grouped 的列 #FFFFFF、grouped 背景 `systemGroupedBackground` #F2F2F7、
    /// 卡片與 shell 區塊的淡填色疊在白底上 #EFEFF0;
    /// 深色：主要背景 #000000、grouped 背景與 `secondarySystemBackground` #1C1C1E、grouped 的列 #2C2C2E。
    static let lightSecondaryBackgrounds = [
        ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF), ThemeColor(red: 0xF2, green: 0xF2, blue: 0xF7),
        ThemeColor(red: 0xEF, green: 0xEF, blue: 0xF0),
    ]
    static let darkSecondaryBackgrounds = [
        ThemeColor(red: 0x00, green: 0x00, blue: 0x00), ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E),
        ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E),
    ]

    @Test("次要文字：深淺色對主要與 grouped 背景 ≥ 4.5:1,高對比 ≥ 7:1")
    func secondaryTextContrast() {
        let palette = AccessibleColors.secondaryText
        let cases: [(String, ThemeColor, [ThemeColor], Double)] = [
            ("淺色", palette.light, Self.lightSecondaryBackgrounds, 4.5),
            ("深色", palette.dark, Self.darkSecondaryBackgrounds, 4.5),
            ("淺色高對比", palette.lightHighContrast, Self.lightSecondaryBackgrounds, 7),
            ("深色高對比", palette.darkHighContrast, Self.darkSecondaryBackgrounds, 7),
        ]
        for (name, color, backgrounds, minimum) in cases {
            for background in backgrounds {
                let ratio = color.contrastRatio(with: background)
                #expect(ratio >= minimum, "\(name) \(color) 對 \(background) 只有 \(ratio)")
            }
        }
    }
}

/// 主色翡翠綠(ADR-0011):Asset Catalog 的 `AccentColor` 是唯一來源，主色文字與主色填色共用;填色上的字用 `onAccent`。
@Suite("主色")
struct AccentColorTests {
    static let white = ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)
    static let black = ThemeColor(red: 0x00, green: 0x00, blue: 0x00)

    /// Asset Catalog `AccentColor` 的四種外觀(light／dark／各自高對比)。
    static func accentColorAsset() throws -> ContrastPalette {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/App/Purrdr/Assets.xcassets/AccentColor.colorset/Contents.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(root["colors"] as? [[String: Any]])
        var accentByAppearance: [String: ThemeColor] = [:]
        for entry in entries {
            let appearances = (entry["appearances"] as? [[String: String]] ?? [])
                .map { "\($0["appearance"] ?? "")=\($0["value"] ?? "")" }
            let components = try #require((entry["color"] as? [String: Any])?["components"] as? [String: String])
            func channel(_ key: String) throws -> UInt8 {
                let text = try #require(components[key])
                return try #require(UInt8(text.dropFirst(2), radix: 16), "\(key) 不是 0xHH:\(text)")
            }
            let name = (appearances.contains("luminosity=dark") ? "dark" : "light")
                + (appearances.contains("contrast=high") ? "HighContrast" : "")
            accentByAppearance[name] = ThemeColor(red: try channel("red"), green: try channel("green"), blue: try channel("blue"))
        }
        return ContrastPalette(
            light: try #require(accentByAppearance["light"]),
            dark: try #require(accentByAppearance["dark"]),
            lightHighContrast: try #require(accentByAppearance["lightHighContrast"]),
            darkHighContrast: try #require(accentByAppearance["darkHighContrast"])
        )
    }

    @Test("AccentColor 是翡翠綠四值")
    func accentColorIsEmerald() throws {
        let accent = try Self.accentColorAsset()
        #expect(accent.light == ThemeColor(hex: "#0B7A5C"))
        #expect(accent.dark == ThemeColor(hex: "#3CCF9E"))
        #expect(accent.lightHighContrast == ThemeColor(hex: "#075C45"))
        #expect(accent.darkHighContrast == ThemeColor(hex: "#5DE0B3"))
    }

    /// HIG:一般文字 ≥ 4.5:1;「增加對比」的值要比一般值更強。
    @Test("主色文字：四值對主要、grouped 與卡片背景 ≥ 4.5:1,高對比值更強")
    func accentTextContrast() throws {
        let accent = try Self.accentColorAsset()
        let cases: [(String, ThemeColor, ThemeColor, [ThemeColor])] = [
            ("淺色", accent.light, accent.lightHighContrast, AccessibleColorsTests.lightSecondaryBackgrounds),
            ("深色", accent.dark, accent.darkHighContrast, AccessibleColorsTests.darkSecondaryBackgrounds),
        ]
        for (name, normal, highContrast, backgrounds) in cases {
            for background in backgrounds {
                let normalRatio = normal.contrastRatio(with: background)
                let highContrastRatio = highContrast.contrastRatio(with: background)
                #expect(normalRatio >= 4.5, "\(name) \(normal) 對 \(background) 只有 \(normalRatio)")
                #expect(highContrastRatio >= 4.5, "\(name)高對比 \(highContrast) 對 \(background) 只有 \(highContrastRatio)")
                #expect(highContrastRatio > normalRatio, "\(name)高對比 \(highContrast) 沒有比一般值更強")
            }
        }
    }

    @Test("主色上的字色：淺色白、深色黑")
    func onAccentIsWhiteInLightAndBlackInDark() {
        let onAccent = AccessibleColors.onAccent
        #expect(onAccent.light == Self.white)
        #expect(onAccent.lightHighContrast == Self.white)
        #expect(onAccent.dark == Self.black)
        #expect(onAccent.darkHighContrast == Self.black)
    }

    @Test("主色上的字色：對主色四值 ≥ 4.5:1")
    func onAccentContrast() throws {
        let accent = try Self.accentColorAsset()
        let onAccent = AccessibleColors.onAccent
        let cases: [(String, ThemeColor, ThemeColor)] = [
            ("淺色", onAccent.light, accent.light),
            ("深色", onAccent.dark, accent.dark),
            ("淺色高對比", onAccent.lightHighContrast, accent.lightHighContrast),
            ("深色高對比", onAccent.darkHighContrast, accent.darkHighContrast),
        ]
        for (name, foreground, background) in cases {
            let ratio = foreground.contrastRatio(with: background)
            #expect(ratio >= 4.5, "\(name) \(foreground) 對主色 \(background) 只有 \(ratio)")
        }
    }
}

/// Spaces 檢視新增的顏色(#103)。
@Suite("Spaces 檢視的配色")
struct SpacesColorsTests {
    static let white = ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)

    @Test("Agent 種類頭像：已知種類各有字母，其他種類用顯示名的首字母")
    func avatarLetters() {
        let kinds: [AgentKind] = [.claudeCode, .codex, .gemini, .openCode, .copilot, .unknown("grok"), .unknown("pi")]
        let letters = kinds.map { AgentKindAvatarStyle(kind: $0).letter }
        #expect(letters == ["C", "X", "G", "O", "P", "G", "P"])
    }

    @Test("Agent 種類頭像的白色字母：底色深淺色 ≥ 4.5:1,高對比 ≥ 7:1")
    func avatarContrast() {
        for kind in [AgentKind.claudeCode, .codex, .gemini, .openCode, .copilot, .unknown("grok")] {
            let palette = AgentKindAvatarStyle(kind: kind).palette
            for (name, color, minimum) in [
                ("淺色", palette.light, 4.5), ("深色", palette.dark, 4.5),
                ("淺色高對比", palette.lightHighContrast, 7.0), ("深色高對比", palette.darkHighContrast, 7.0),
            ] {
                let ratio = Self.white.contrastRatio(with: color)
                #expect(ratio >= minimum, "\(kind) \(name) \(color) 只有 \(ratio)")
            }
        }
    }
}

/// 方案用量圓環的三級顏色(#177)。
@Suite("方案用量的配色")
struct PlanUsageColorsTests {
    static let white = ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)
    static let darkCards = [ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E), ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E)]

    /// 非文字圖形(WCAG 1.4.11):對圓環所在的列背景 ≥ 3:1,高對比 ≥ 4.5:1。淺色列 #FFFFFF;深色列 #1C1C1E、#2C2C2E。
    @Test("圓環的充足、偏低、將用完三級：對列背景 ≥ 3:1,高對比 ≥ 4.5:1")
    func levelContrast() {
        for level in [PlanUsageLevel.ample, .low, .depleted] {
            let palette = AccessibleColors.planUsage(level)
            let cases: [(String, ThemeColor, [ThemeColor], Double)] = [
                ("淺色", palette.light, [Self.white], 3), ("深色", palette.dark, Self.darkCards, 3),
                ("淺色高對比", palette.lightHighContrast, [Self.white], 4.5),
                ("深色高對比", palette.darkHighContrast, Self.darkCards, 4.5),
            ]
            for (name, color, backgrounds, minimum) in cases {
                for background in backgrounds {
                    let ratio = color.contrastRatio(with: background)
                    #expect(ratio >= minimum, "\(level) \(name) \(color) 對 \(background) 只有 \(ratio)")
                }
            }
        }
    }

    @Test("三級的顏色彼此不同(綠、橘、紅)")
    func levelsAreDistinct() {
        let palettes = [PlanUsageLevel.ample, .low, .depleted].map { AccessibleColors.planUsage($0) }
        #expect(palettes[0].light.green > palettes[0].light.red, "充足不是綠色")
        #expect(palettes[1].light.red > palettes[1].light.green && palettes[1].light.green > palettes[1].light.blue, "偏低不是橘色")
        #expect(Int(palettes[2].light.red) > Int(palettes[2].light.green) * 2, "將用完不是紅色")
    }
}

/// 建議卡「填入」膠囊(#240):主色字放在主色淡疊的底上，底是卡片的 `.background`(淺色白、深色黑或 #1C1C1E)。
@Suite("建議卡的填入膠囊")
struct SuggestionFillInContrastTests {
    static func composite(_ color: ThemeColor, over background: ThemeColor, opacity: Double) -> ThemeColor {
        func channel(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            UInt8((opacity * Double(top) + (1 - opacity) * Double(bottom)).rounded())
        }
        return ThemeColor(
            red: channel(color.red, background.red), green: channel(color.green, background.green),
            blue: channel(color.blue, background.blue))
    }

    @Test("主色字對淡綠底：四值 ≥ 4.5:1")
    func fillInTextContrast() throws {
        let accent = try AccentColorTests.accentColorAsset()
        let opacity = PromptSuggestionView.fillInTintOpacity
        let darkCards = [ThemeColor(red: 0x00, green: 0x00, blue: 0x00), ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E)]
        let cases: [(String, ThemeColor, [ThemeColor])] = [
            ("淺色", accent.light, [AccentColorTests.white]), ("淺色高對比", accent.lightHighContrast, [AccentColorTests.white]),
            ("深色", accent.dark, darkCards), ("深色高對比", accent.darkHighContrast, darkCards),
        ]
        for (name, color, cards) in cases {
            for card in cards {
                let ratio = color.contrastRatio(with: Self.composite(color, over: card, opacity: opacity))
                #expect(ratio >= 4.5, "\(name) \(color) 對卡片 \(card) 上的淡綠底只有 \(ratio)")
            }
        }
    }
}
