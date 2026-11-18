import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 承載文字的自訂顏色對比(#35;HIG 20.2:文字對比 ≥ 4.5:1,Increase Contrast 時 ≥ 7:1)。
@Suite("無障礙配色")
struct AccessibleColorsTests {
    /// 錯誤文字可能落在的背景裡最不利的那個(固定值，取自 iOS 系統色):
    /// 淺色是 shell 區塊的 `.fill.tertiary`(rgba(118,118,128,0.12))疊在白底上 = #EFEFF0;
    /// 深色是 grouped list 第二層 `secondarySystemGroupedBackground`／`secondarySystemBackground` = #2C2C2E。
    static let lightBackground = ThemeColor(red: 0xEF, green: 0xEF, blue: 0xF0)
    static let darkBackground = ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E)

    @Test("錯誤文字：深淺色 ≥ 4.5:1,高對比 ≥ 7:1")
    func errorTextContrast() {
        let palette = AccessibleColors.errorText
        let light = palette.light.contrastRatio(with: Self.lightBackground)
        let dark = palette.dark.contrastRatio(with: Self.darkBackground)
        let lightHigh = palette.lightHighContrast.contrastRatio(with: Self.lightBackground)
        let darkHigh = palette.darkHighContrast.contrastRatio(with: Self.darkBackground)
        #expect(light >= 4.5, "淺色 \(light)")
        #expect(dark >= 4.5, "深色 \(dark)")
        #expect(lightHigh >= 7, "淺色高對比 \(lightHigh)")
        #expect(darkHigh >= 7, "深色高對比 \(darkHigh)")
    }

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

/// 品牌紅的兩個角色(#70):紅字對它出現的背景、白字對紅底，四種外觀各自達標;`AccentColor` 與紅字同值。
@Suite("品牌紅角色")
struct BrandRedTests {
    static let white = ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)

    @Test("紅字：深淺色對主要、grouped 與卡片背景 ≥ 4.5:1,高對比 ≥ 7:1")
    func brandTextContrast() {
        let palette = AccessibleColors.brandText
        let cases: [(String, ThemeColor, [ThemeColor], Double)] = [
            ("淺色", palette.light, AccessibleColorsTests.lightSecondaryBackgrounds, 4.5),
            ("深色", palette.dark, AccessibleColorsTests.darkSecondaryBackgrounds, 4.5),
            ("淺色高對比", palette.lightHighContrast, AccessibleColorsTests.lightSecondaryBackgrounds, 7),
            ("深色高對比", palette.darkHighContrast, AccessibleColorsTests.darkSecondaryBackgrounds, 7),
        ]
        for (name, color, backgrounds, minimum) in cases {
            for background in backgrounds {
                let ratio = color.contrastRatio(with: background)
                #expect(ratio >= minimum, "\(name) \(color) 對 \(background) 只有 \(ratio)")
            }
        }
    }

    @Test("紅底：白字對它深淺色 ≥ 4.5:1,高對比 ≥ 7:1")
    func brandFillContrast() {
        let palette = AccessibleColors.brandFill
        let cases: [(String, ThemeColor, Double)] = [
            ("淺色", palette.light, 4.5),
            ("深色", palette.dark, 4.5),
            ("淺色高對比", palette.lightHighContrast, 7),
            ("深色高對比", palette.darkHighContrast, 7),
        ]
        for (name, color, minimum) in cases {
            let ratio = Self.white.contrastRatio(with: color)
            #expect(ratio >= minimum, "\(name) 白字對 \(color) 只有 \(ratio)")
        }
    }

    @Test("iPad 選取列：列文字與「需要你」對選取底色深淺色 ≥ 4.5:1,高對比 ≥ 7:1")
    func selectedRowContrast() {
        let text = AccessibleColors.selectedRowText
        let fill = AccessibleColors.selectionFill
        let cases: [(String, ThemeColor, ThemeColor, Double)] = [
            ("淺色", text.light, fill.light, 4.5),
            ("深色", text.dark, fill.dark, 4.5),
            ("淺色高對比", text.lightHighContrast, fill.lightHighContrast, 7),
            ("深色高對比", text.darkHighContrast, fill.darkHighContrast, 7),
        ]
        for (name, foreground, background, minimum) in cases {
            let ratio = foreground.contrastRatio(with: background)
            #expect(ratio >= minimum, "\(name) \(foreground) 對選取底色 \(background) 只有 \(ratio)")
        }
    }

    @Test("AccentColor 四種外觀與紅字同值")
    func accentColorMatchesBrandText() throws {
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
        let palette = AccessibleColors.brandText
        #expect(accentByAppearance == [
            "light": palette.light, "dark": palette.dark,
            "lightHighContrast": palette.lightHighContrast, "darkHighContrast": palette.darkHighContrast,
        ])
    }
}

/// 對話中的連結(#93):系統連結藍的色相，與品牌紅的強調元素分開;四種外觀對主要與卡片背景達標。
@Suite("連結顏色")
struct LinkTextTests {
    static let appearances: [(String, ThemeColor, [ThemeColor], Double)] = [
        ("淺色", AccessibleColors.linkText.light, AccessibleColorsTests.lightSecondaryBackgrounds, 4.5),
        ("深色", AccessibleColors.linkText.dark, AccessibleColorsTests.darkSecondaryBackgrounds, 4.5),
        ("淺色高對比", AccessibleColors.linkText.lightHighContrast, AccessibleColorsTests.lightSecondaryBackgrounds, 7),
        ("深色高對比", AccessibleColors.linkText.darkHighContrast, AccessibleColorsTests.darkSecondaryBackgrounds, 7),
    ]

    @Test("連結：深淺色對主要、grouped 與卡片背景 ≥ 4.5:1,高對比 ≥ 7:1")
    func linkTextContrast() {
        for (name, color, backgrounds, minimum) in Self.appearances {
            for background in backgrounds {
                let ratio = color.contrastRatio(with: background)
                #expect(ratio >= minimum, "\(name) \(color) 對 \(background) 只有 \(ratio)")
            }
        }
    }

    @Test("連結是藍色，不是品牌紅")
    func linkTextIsBlue() {
        for (name, color, _, _) in Self.appearances {
            #expect(color.blue > color.red && color.blue > color.green, "\(name) \(color) 不是藍色")
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

    /// 非文字圖形(WCAG 1.4.11):對列的背景 ≥ 3:1,高對比 ≥ 4.5:1。淺色列 #FFFFFF;深色列 #1C1C1E、#2C2C2E。
    @Test("狀態條的閒置段：對列背景 ≥ 3:1,高對比 ≥ 4.5:1")
    func idleSegmentContrast() {
        let palette = AccessibleColors.idleSegment
        let darkRows = [ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E), ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E)]
        let cases: [(String, ThemeColor, [ThemeColor], Double)] = [
            ("淺色", palette.light, [Self.white], 3), ("深色", palette.dark, darkRows, 3),
            ("淺色高對比", palette.lightHighContrast, [Self.white], 4.5), ("深色高對比", palette.darkHighContrast, darkRows, 4.5),
        ]
        for (name, color, backgrounds, minimum) in cases {
            for background in backgrounds {
                let ratio = color.contrastRatio(with: background)
                #expect(ratio >= minimum, "\(name) \(color) 對 \(background) 只有 \(ratio)")
            }
        }
    }
}
