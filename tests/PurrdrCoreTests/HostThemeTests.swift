import Foundation
import PurrdrCore
import Testing

/// 主機主題(#23):讀主機 herdr 的 `config.toml` 的 `[theme]`,換成 app 與終端機的配色。
/// 文字對比不足 4.5:1 的顏色一律丟棄，退回系統配色。
@Suite("主機主題")
struct HostThemeTests {
    static func theme(_ toml: String) -> HostTheme { HostTheme(config: HerdrThemeConfig(toml: toml)) }

    @Test("沒有 config.toml:herdr 預設 catppuccin,終端機用它的背景與文字色")
    func missingConfigUsesHerdrDefault() {
        let theme = HostTheme(config: HerdrThemeConfig(toml: nil))
        #expect(theme.name == "catppuccin")
        #expect(theme.terminal?.background == ThemeColor(hex: "#1e1e2e"))
        #expect(theme.terminal?.foreground == ThemeColor(hex: "#cdd6f4"))
    }

    @Test("[theme.custom] 的 accent:深色背景對比夠就套用為 tint;淺色背景對比不足退回系統(nil)")
    func accentNeedsContrastPerAppearance() {
        let theme = Self.theme("""
            [theme]
            name = "tokyo-night" # 內嵌註解
            [theme.custom]
            accent = "#7aa2f7"
            """)
        #expect(theme.app(.dark).tint == ThemeColor(hex: "#7aa2f7"))
        #expect(theme.app(.light).tint == nil)
    }

    @Test("填色(使用者泡泡、送出鈕):白字對比 ≥ 4.5 才用 accent")
    func fillNeedsWhiteTextContrast() {
        let dark = Self.theme("[theme.custom]\naccent = \"#d20f39\"\n")
        #expect(dark.app(.light).fill == ThemeColor(hex: "#d20f39"))
        let pastel = Self.theme("[theme.custom]\naccent = 'rgb(166, 227, 161)'\n")
        #expect(pastel.app(.light).fill == nil)
        #expect(pastel.app(.dark).fill == nil)
    }

    @Test("終端機文字與背景對比不足：整組退回系統終端機配色")
    func lowContrastTerminalFallsBack() {
        let theme = Self.theme("""
            [theme.custom]
            panel_bg = "#1e1e2e"
            text = "#2a2a3a"
            """)
        #expect(theme.terminal == nil)
    }

    @Test("ANSI 顏色對比不足的那一格丟棄(用系統的),其餘照用")
    func lowContrastANSISlotDropped() throws {
        let theme = Self.theme("""
            [theme]
            name = "catppuccin"
            [theme.custom]
            red = "#2b1b1b"
            green = "green"
            """)
        let terminal = try #require(theme.terminal)
        #expect(terminal.ansi[1] == nil)
        #expect(terminal.ansi[9] == nil)
        // 具名的 green(#008000)對 #1e1e2e 只有約 3.2:1。
        #expect(terminal.ansi[2] == nil)
        #expect(terminal.ansi[4] == ThemeColor(hex: "#89b4fa"))
    }

    @Test("不認得的內建主題、沒有自訂顏色：全部用系統配色")
    func unknownBuiltInUsesSystem() {
        let theme = Self.theme("[theme]\nname = \"vesper\"\n")
        #expect(theme.terminal == nil)
        #expect(theme.app(.dark).tint == nil)
        #expect(theme.app(.light).tint == nil)
    }

    @Test("auto_switch:淺色用 light_name、深色用 dark_name,再疊 [theme.custom.light]/[theme.custom.dark]")
    func autoSwitchPicksPerAppearance() {
        let theme = Self.theme("""
            [theme]
            name = "catppuccin"
            auto_switch = true
            light_name = "catppuccin-latte"
            [theme.custom.dark]
            accent = "#89b4fa"
            """)
        #expect(theme.app(.light).tint == ThemeColor(hex: "#8839ef"))
        #expect(theme.app(.dark).tint == ThemeColor(hex: "#89b4fa"))
    }

    @Test("沒有 auto_switch 時忽略 light/dark 子表(herdr 文件)")
    func modeTablesIgnoredWithoutAutoSwitch() {
        let theme = Self.theme("""
            [theme.custom.dark]
            accent = "#89b4fa"
            """)
        #expect(theme.app(.dark).tint == ThemeColor(hex: "#cba6f7"))
    }

    @Test("reset 別名：該顏色回到主題預設以外的系統色;壞顏色略過")
    func resetAndInvalidColors() {
        let theme = Self.theme("""
            [theme.custom]
            panel_bg = "reset"
            accent = "#zzzzzz"
            """)
        #expect(theme.terminal == nil)
        #expect(theme.app(.dark).tint == ThemeColor(hex: "#cba6f7"))
    }

    @Test("對比計算(WCAG):白對黑 21:1、#D91E36 對白 約 5.0:1")
    func contrastRatio() throws {
        let white = try #require(ThemeColor(hex: "#ffffff"))
        let black = try #require(ThemeColor(hex: "#000"))
        #expect(abs(white.contrastRatio(with: black) - 21) < 0.01)
        let red = try #require(ThemeColor(hex: "#D91E36"))
        #expect(abs(red.contrastRatio(with: white) - 5.0) < 0.1)
    }

    @Test("其他段落([keys]、[terminal])與陣列表不影響主題")
    func otherSectionsIgnored() {
        let theme = Self.theme("""
            onboarding = false
            [terminal]
            default_shell = "/bin/zsh"
            [[keys.command]]
            name = "accent"
            [theme]
            name = "dracula"
            """)
        #expect(theme.name == "dracula")
        #expect(theme.terminal?.background == ThemeColor(hex: "#282a36"))
    }
}
