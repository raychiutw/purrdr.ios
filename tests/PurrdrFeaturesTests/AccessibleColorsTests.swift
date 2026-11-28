import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 承載文字的自訂顏色對比(#35;HIG 20.2:文字對比 ≥ 4.5:1,Increase Contrast 時 ≥ 7:1)。
@Suite("無障礙配色")
struct AccessibleColorsTests {
    /// 文字可能落在的系統背景(#646;值是 iOS 27.0 模擬器實測,見 docs/research/ios27-dark-mode-colors.md §1.2):
    /// 淺色:`systemBackground` #FFFFFF、grouped 背景與 `secondarySystemBackground` #F2F2F7、
    /// 卡片與 shell 區塊的淡填色疊在白底上 #EFEFF0;增加對比時 grouped／secondary 為 #EBEBF0。
    /// 深色:base 的 #000000／#1C1C1E／#2C2C2E 與 elevated 的 #1C1C1E／#2C2C2E／#3A3A3C;
    /// 增加對比 base #000000／#242426／#363638、elevated #242426／#363638／#444446。
    static let lightSecondaryBackgrounds = [
        ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF), ThemeColor(red: 0xF2, green: 0xF2, blue: 0xF7),
        ThemeColor(red: 0xEF, green: 0xEF, blue: 0xF0),
    ]
    static let lightHighContrastBackgrounds = [
        ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF), ThemeColor(red: 0xEB, green: 0xEB, blue: 0xF0),
        ThemeColor(red: 0xEF, green: 0xEF, blue: 0xF0),
    ]
    static let darkSecondaryBackgrounds = [
        ThemeColor(red: 0x00, green: 0x00, blue: 0x00), ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E),
        ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E), ThemeColor(red: 0x3A, green: 0x3A, blue: 0x3C),
    ]
    static let darkHighContrastBackgrounds = [
        ThemeColor(red: 0x00, green: 0x00, blue: 0x00), ThemeColor(red: 0x24, green: 0x24, blue: 0x26),
        ThemeColor(red: 0x36, green: 0x36, blue: 0x38), ThemeColor(red: 0x44, green: 0x44, blue: 0x46),
    ]

    @Test("紅字按鈕文字:深淺色對主要、grouped、卡片與再內一層背景 ≥ 4.5:1,高對比 ≥ 7:1(#379)")
    func destructiveTextContrast() {
        Self.expectReadable(AccessibleColors.destructiveText)
    }

    @Test("未讀徽章:白字對徽章底色深淺色 ≥ 4.5:1,高對比 ≥ 7:1;系統紅(#FF3B30／#FF453A)不足所以不用(#639)")
    func unreadBadgeContrast() {
        let white = ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)
        let palette = AccessibleColors.unreadBadge
        for (name, background, minimum) in [
            ("淺色", palette.light, 4.5), ("深色", palette.dark, 4.5),
            ("淺色高對比", palette.lightHighContrast, 7), ("深色高對比", palette.darkHighContrast, 7),
        ] {
            let ratio = white.contrastRatio(with: background)
            #expect(ratio >= minimum, "\(name) 白字對 \(background) 只有 \(ratio)")
        }
        // 記下為什麼要換:系統紅底白字不到 4.5:1。
        #expect(white.contrastRatio(with: ThemeColor(red: 0xFF, green: 0x3B, blue: 0x30)) < 4.5)
        #expect(white.contrastRatio(with: ThemeColor(red: 0xFF, green: 0x45, blue: 0x3A)) < 4.5)
    }

    @Test("次要文字淺色:自訂灰對實際背景 ≥ 4.5:1,增加對比 ≥ 7:1(系統 secondaryLabel 白底只有 3.4:1,所以淺色不用)")
    func secondaryTextLightContrast() {
        let pair = AccessibleColors.secondaryTextLight
        for background in Self.lightSecondaryBackgrounds {
            #expect(pair.normal.contrastRatio(with: background) >= 4.5, "淺色 \(pair.normal) 對 \(background)")
        }
        for background in Self.lightHighContrastBackgrounds {
            #expect(pair.highContrast.contrastRatio(with: background) >= 7, "淺色高對比 \(pair.highContrast) 對 \(background)")
        }
        // 記下為什麼淺色不用系統色:secondaryLabel #3C3C43 α0.6 疊在白底約 #8A8A8E。
        #expect(ThemeColor(red: 0x8A, green: 0x8A, blue: 0x8E).contrastRatio(with: Self.lightSecondaryBackgrounds[0]) < 4.5)
    }

    @Test("次要文字深色:系統 secondaryLabel(#EBEBF5 α0.6／增加對比 α0.7)疊在實際深色背景 ≥ 4.5:1,所以不另設自訂色")
    func secondaryTextDarkSystemLabelIsReadable() {
        let label = ThemeColor(red: 0xEB, green: 0xEB, blue: 0xF5)
        for (backgrounds, alpha) in [(Self.darkSecondaryBackgrounds, 0.6), (Self.darkHighContrastBackgrounds, 0.7)] {
            for background in backgrounds {
                let composed = SuggestionFillInContrastTests.composite(label, over: background, opacity: alpha)
                let ratio = composed.contrastRatio(with: background)
                #expect(ratio >= 4.5, "深色 secondaryLabel α\(alpha) 對 \(background) 只有 \(ratio)")
            }
        }
    }

    static func expectReadable(_ palette: ContrastPalette) {
        let cases: [(String, ThemeColor, [ThemeColor], Double)] = [
            ("淺色", palette.light, Self.lightSecondaryBackgrounds, 4.5),
            ("深色", palette.dark, Self.darkSecondaryBackgrounds, 4.5),
            ("淺色高對比", palette.lightHighContrast, Self.lightHighContrastBackgrounds, 7),
            ("深色高對比", palette.darkHighContrast, Self.darkHighContrastBackgrounds, 7),
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
        let kinds: [AgentID] = [.claude, .codex, .gemini, .opencode, .copilot, .grok, .pi]
        let letters = kinds.map { AgentKindAvatarStyle(kind: $0).letter }
        #expect(letters == ["C", "X", "G", "O", "P", "G", "P"])
    }

    @Test("Agent 種類頭像底色是低飽和多色(#242 方案 B),深淺色共用、高對比更深")
    func avatarColorsAreMutedPalette() {
        let expected: [(AgentID, String, String)] = [
            (.claude, "#8A5A48", "#6D4739"), (.codex, "#55565C", "#4F5056"), (.gemini, "#4A5F86", "#3E5071"),
            (.opencode, "#8A4F66", "#6D3A4F"), (.copilot, "#6A5884", "#58496E"), (.grok, "#5A5A5F", "#505055"),
        ]
        for (kind, normal, highContrast) in expected {
            let palette = AgentKindAvatarStyle(kind: kind).palette
            #expect(palette.light == ThemeColor(hex: normal), "\(kind) 一般值")
            #expect(palette.dark == ThemeColor(hex: normal), "\(kind) 深色值")
            #expect(palette.lightHighContrast == ThemeColor(hex: highContrast), "\(kind) 高對比值")
            #expect(palette.darkHighContrast == ThemeColor(hex: highContrast), "\(kind) 深色高對比值")
            #expect(Self.white.contrastRatio(with: palette.lightHighContrast) > Self.white.contrastRatio(with: palette.light),
                    "\(kind) 高對比沒有更深")
        }
    }

    @Test("Agent 種類頭像的白色字母：底色深淺色 ≥ 4.5:1,高對比 ≥ 7:1")
    func avatarContrast() {
        for kind in [AgentID.claude, .codex, .gemini, .opencode, .copilot, .grok] {
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

/// 低飽和用量色三級(#177、#389)。
@Suite("方案用量的配色")
struct PlanUsageColorsTests {
    static let white = ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF)
    // 軌道是系統 tertiarySystemFill(118,118,128;淺色 α.12、深色 α.24)疊在實際底上的合成值
    static let groupedTrack = ThemeColor(red: 0xE3, green: 0xE3, blue: 0xE9)   // 疊在 grouped 底 #F2F2F7
    static let whiteTrack = ThemeColor(red: 0xEF, green: 0xEF, blue: 0xF0)     // 疊在白色卡片
    static let darkTracks = [ThemeColor(red: 0x32, green: 0x32, blue: 0x36), ThemeColor(red: 0x3E, green: 0x3E, blue: 0x42)] // 疊在 #1C1C1E、#2C2C2E
    static let darkCards = [ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E), ThemeColor(red: 0x2C, green: 0x2C, blue: 0x2E)]

    /// 非文字圖形(WCAG 1.4.11):對軌道與卡片底 ≥ 3:1,高對比 ≥ 4.5:1。
    /// 三級在淺色對白卡、白卡軌道與 grouped 軌道都要 ≥ 3:1(軌道改系統填色後,70% 淺色調深為 #9E6E40 才達標)。
    @Test("三級:對軌道與卡片 ≥ 3:1(含淺色 grouped 軌道),高對比 ≥ 4.5:1")
    func levelContrast() {
        for level in [PlanUsageLevel.ample, .low, .depleted] {
            let palette = AccessibleColors.planUsage(level)
            let lightBackgrounds = [Self.white, Self.whiteTrack, Self.groupedTrack]
            let cases: [(String, ThemeColor, [ThemeColor], Double)] = [
                ("淺色", palette.light, lightBackgrounds, 3), ("深色", palette.dark, Self.darkCards + Self.darkTracks, 3),
                ("淺色高對比", palette.lightHighContrast, [Self.white, Self.whiteTrack, Self.groupedTrack], 4.5),
                ("深色高對比", palette.darkHighContrast, Self.darkCards + Self.darkTracks, 4.5),
            ]
            for (name, color, backgrounds, minimum) in cases {
                for background in backgrounds {
                    let ratio = color.contrastRatio(with: background)
                    #expect(ratio >= minimum, "\(level) \(name) \(color) 對 \(background) 只有 \(ratio)")
                }
            }
        }
    }

    @Test("「充足」就是主色(#649):四個值等於 AccentColor Asset,不是另一種灰綠")
    func ampleIsAccent() throws {
        let accent = try AccentColorTests.accentColorAsset()
        let ample = AccessibleColors.planUsageAmple
        #expect(ample.light == accent.light && ample.dark == accent.dark)
        #expect(ample.lightHighContrast == accent.lightHighContrast && ample.darkHighContrast == accent.darkHighContrast)
    }

    /// 70% 級距深色優先用系統橙(#649):系統橙(約 #FF9230,增加對比約 #FFB340)對深色軌道與卡片底都 ≥ 3:1,所以深色用系統色
    /// (近似值在這裡驗對比;「解析出的就是實際 UIColor.systemOrange」在 tests/PurrdrIOSTests 的 `PlanUsageSystemColorTests`);
    /// 淺色系統橙對白底只有 2.2:1,不足,維持自訂色。85% 級距系統紅對深色軌道只有 2.8～3.0:1(淺色 2.6～3.0:1),不足,維持自訂色。
    @Test("70% 級距:深色(含增加對比)是系統橙,對軌道與卡片底 ≥ 3:1;淺色系統橙 < 3:1 所以自訂")
    func lowLevelUsesSystemOrangeInDark() {
        let low = AccessibleColors.planUsageLow
        #expect(low.dark == ThemeColor(hex: "#FF9230"))
        #expect(low.darkHighContrast == ThemeColor(hex: "#FFB340"))
        #expect(low.usesSystemInDark, "深色外觀交給系統橙")
        for background in Self.darkCards + Self.darkTracks {
            #expect(low.dark.contrastRatio(with: background) >= 3, "\(background)")
        }
        #expect(ThemeColor(red: 0xFF, green: 0x95, blue: 0x00).contrastRatio(with: Self.white) < 3, "淺色系統橙不足才用自訂")
        #expect(!AccessibleColors.planUsageDepleted.usesSystemInDark)
    }

    @Test("三級的顏色彼此不同(低飽和的綠、棕橘、紅)")
    func levelsAreDistinct() {
        let palettes = [PlanUsageLevel.ample, .low, .depleted].map { AccessibleColors.planUsage($0) }
        #expect(palettes[0].light.green > palettes[0].light.red, "正常不是綠色")
        #expect(palettes[1].light.red > palettes[1].light.green && palettes[1].light.green > palettes[1].light.blue, "偏高不是橘棕色")
        #expect(Int(palettes[2].light.red) > Int(palettes[2].light.green), "將用完不是紅色")
        #expect(palettes[1].light != palettes[2].light)
    }
}

/// 流量圖兩階綠(#649):行動網路 = 主色,Wi-Fi = 同色相的另一階;對頁面 ≥ 3:1、兩者看得出差別。
@Suite("流量圖的配色")
struct DataUsageColorsTests {
    /// 長條實際出現的背景:grouped 頁(淺色 `#F2F2F7`、深色 base 純黑)與卡片(白、`#1C1C1E`、`#2C2C2E`),增加對比用系統的增強值。
    static let light = [ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF), ThemeColor(red: 0xF2, green: 0xF2, blue: 0xF7)]
    static let lightHighContrast = [ThemeColor(red: 0xFF, green: 0xFF, blue: 0xFF), ThemeColor(red: 0xEB, green: 0xEB, blue: 0xF0)]
    static let dark = Array(AccessibleColorsTests.darkSecondaryBackgrounds.dropLast())
    static let darkHighContrast = AccessibleColorsTests.darkHighContrastBackgrounds

    @Test("行動網路就是主色(四值等於 AccentColor Asset)")
    func cellularIsAccent() throws {
        let accent = try AccentColorTests.accentColorAsset()
        let cellular = AccessibleColors.dataUsageCellular
        #expect(cellular.light == accent.light && cellular.dark == accent.dark)
        #expect(cellular.lightHighContrast == accent.lightHighContrast && cellular.darkHighContrast == accent.darkHighContrast)
    }

    @Test("Wi-Fi:深淺色與增加對比對頁面與卡片底 ≥ 3:1,與行動網路至少差 1.5:1,且是同色相的綠")
    func wifiContrast() {
        let wifi = AccessibleColors.dataUsageWifi
        let cellular = AccessibleColors.dataUsageCellular
        let cases: [(String, ThemeColor, ThemeColor, [ThemeColor])] = [
            ("淺色", wifi.light, cellular.light, Self.light), ("淺色高對比", wifi.lightHighContrast, cellular.lightHighContrast, Self.lightHighContrast),
            ("深色", wifi.dark, cellular.dark, Self.dark), ("深色高對比", wifi.darkHighContrast, cellular.darkHighContrast, Self.darkHighContrast),
        ]
        for (name, color, cell, backgrounds) in cases {
            for background in backgrounds {
                #expect(color.contrastRatio(with: background) >= 3, "\(name) Wi-Fi \(color) 對 \(background)")
            }
            let gap = color.contrastRatio(with: cell)
            #expect(gap >= 1.5, "\(name) Wi-Fi \(color) 與行動網路 \(cell) 只差 \(gap)")
            #expect(color.green > color.red && color.green >= color.blue, "\(name) 不是綠色")
        }
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
    @MainActor func fillInTextContrast() throws {
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
