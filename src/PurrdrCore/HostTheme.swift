import Foundation

/// 不透明的 sRGB 顏色(主機主題用)。
public struct ThemeColor: Hashable, Sendable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RGB` 或 `#RRGGBB`。
    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xff), green: UInt8(value >> 8 & 0xff), blue: UInt8(value & 0xff))
    }

    /// herdr 接受的顏色寫法(herdr 文件:hex、具名顏色、`rgb(r,g,b)`)。reset 別名與看不懂的值回 `nil`。
    init?(herdr value: String) {
        let value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let color = ThemeColor(hex: value) {
            self = color
        } else if value.hasPrefix("rgb("), value.hasSuffix(")") {
            let parts = value.dropFirst(4).dropLast().split(separator: ",").map { UInt8($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3, let red = parts[0], let green = parts[1], let blue = parts[2] else { return nil }
            self.init(red: red, green: green, blue: blue)
        } else if let named = Self.named[value] {
            self = named
        } else {
            return nil
        }
    }

    /// 具名顏色(CSS 基本色)。herdr 文件沒列出完整清單，認不得的名稱略過。
    static let named: [String: ThemeColor] = [
        "black": .init(red: 0, green: 0, blue: 0), "white": .init(red: 255, green: 255, blue: 255),
        "red": .init(red: 255, green: 0, blue: 0), "green": .init(red: 0, green: 128, blue: 0),
        "blue": .init(red: 0, green: 0, blue: 255), "yellow": .init(red: 255, green: 255, blue: 0),
        "magenta": .init(red: 255, green: 0, blue: 255), "cyan": .init(red: 0, green: 255, blue: 255),
        "gray": .init(red: 128, green: 128, blue: 128), "grey": .init(red: 128, green: 128, blue: 128),
    ]

    public var description: String { String(format: "#%02x%02x%02x", red, green, blue) }

    /// WCAG 2 相對亮度。
    var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2 對比(1～21)。
    public func contrastRatio(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static let white = ThemeColor(red: 255, green: 255, blue: 255)
}

public enum ThemeAppearance: Sendable, CaseIterable { case light, dark }

/// herdr `config.toml` 的 `[theme]`(herdr 0.9.5 文件的 Configuration 與 Config reference)。
///
/// 只解析主題用得到的 TOML 子集：表頭、`鍵 = "字串"`/`'字串'`/`true`/`false`、註解。其他段落一律略過。
public struct HerdrThemeConfig: Equatable, Sendable {
    /// herdr 的預設主題。
    public static let defaultName = "catppuccin"

    public var name: String = defaultName
    public var autoSwitch = false
    public var lightName: String?
    public var darkName: String?
    /// `[theme.custom]`:token → 值(原文;reset 別名也保留，解析時才處理)。
    public var custom: [String: String] = [:]
    public var customLight: [String: String] = [:]
    public var customDark: [String: String] = [:]

    /// `nil` 是主機上沒有 `config.toml`(herdr 用預設)。
    public init(toml: String?) {
        guard let toml else { return }
        var table = ""
        for rawLine in toml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = Self.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                // `[[陣列表]]` 不是主題的一部分。
                table = line.hasPrefix("[[") ? "" : line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let value = Self.value(raw)
            switch table {
            case "theme":
                switch key {
                case "name": if let value { name = value }
                case "auto_switch": autoSwitch = raw == "true"
                case "light_name": lightName = value
                case "dark_name": darkName = value
                default: break
                }
            case "theme.custom": if let value { custom[key] = value }
            case "theme.custom.light": if let value { customLight[key] = value }
            case "theme.custom.dark": if let value { customDark[key] = value }
            default: break
            }
        }
    }

    /// 字串值(不處理跳脫;顏色與主題名稱用不到)。
    static func value(_ raw: String) -> String? {
        guard let quote = raw.first, quote == "\"" || quote == "'", raw.count >= 2, raw.last == quote else { return nil }
        return String(raw.dropFirst().dropLast())
    }

    /// 去掉 `#` 之後的註解(引號內的 `#` 是顏色，不算)。
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    /// 某個外觀用的內建主題名稱(herdr:auto_switch 時用 light_name/dark_name,沒寫就用同系列的兄弟主題)。
    func builtInName(for appearance: ThemeAppearance) -> String {
        guard autoSwitch else { return name }
        switch appearance {
        case .light: return lightName ?? HerdrPalette.lightSibling[name] ?? name
        case .dark: return darkName ?? HerdrPalette.darkSibling[name] ?? name
        }
    }

    /// 某個外觀合併後的 token(內建 → `[theme.custom]` → auto_switch 時的 light/dark 子表)。reset 別名讓 token 變成沒有值。
    func tokens(for appearance: ThemeAppearance) -> [String: ThemeColor] {
        var tokens = HerdrPalette.builtIn[builtInName(for: appearance)] ?? [:]
        var layers = [custom]
        if autoSwitch { layers.append(appearance == .light ? customLight : customDark) }
        for layer in layers {
            for (key, value) in layer {
                if HerdrPalette.resetAliases.contains(value.lowercased()) {
                    tokens[key] = nil
                } else if let color = ThemeColor(herdr: value) {
                    tokens[key] = color
                }
            }
        }
        return tokens
    }
}

/// App 介面用的主題顏色(一個外觀)。`nil` = 用系統／App 預設。
public struct AppThemeColors: Equatable, Sendable {
    /// 文字與圖示的強調色(連結、「需要你」):對背景 ≥ 4.5:1。
    public var tint: ThemeColor?
    /// 放白字的填色(使用者泡泡、送出鈕):白字對它 ≥ 4.5:1。
    public var fill: ThemeColor?

    public init(tint: ThemeColor? = nil, fill: ThemeColor? = nil) {
        self.tint = tint
        self.fill = fill
    }
}

/// 終端機配色。`ansi` 固定 16 格，`nil` 的格子用系統預設。
public struct TerminalTheme: Equatable, Sendable {
    public var background: ThemeColor
    public var foreground: ThemeColor
    public var ansi: [ThemeColor?]
    public var cursor: ThemeColor?
}

/// 套用主機 herdr 主題後的配色(#23)。每個文字／背景配對都檢查對比，不足 4.5:1 的退回系統配色。
public struct HostTheme: Equatable, Sendable {
    /// 文字最低對比(WCAG AA,HIG)。
    public static let minimumContrast = 4.5
    /// 游標這類非文字元素的最低對比。
    static let minimumGraphicContrast = 3.0
    /// 對比檢查用的系統背景：淺色是 grouped 背景 `#F2F2F7`,深色是次要背景 `#1C1C1E`(兩者都是較嚴的一邊)。
    static let appBackground: [ThemeAppearance: ThemeColor] = [
        .light: ThemeColor(red: 0xF2, green: 0xF2, blue: 0xF7), .dark: ThemeColor(red: 0x1C, green: 0x1C, blue: 0x1E),
    ]

    public var name: String
    private var colors: [ThemeAppearance: AppThemeColors]
    /// 終端機永遠以深色外觀顯示(DESIGN.md),所以用深色那組 token。
    public var terminal: TerminalTheme?

    public init(config: HerdrThemeConfig) {
        name = config.builtInName(for: .dark)
        var colors: [ThemeAppearance: AppThemeColors] = [:]
        for appearance in ThemeAppearance.allCases {
            let accent = config.tokens(for: appearance)["accent"]
            let background = Self.appBackground[appearance]!
            colors[appearance] = AppThemeColors(
                tint: accent.flatMap { $0.contrastRatio(with: background) >= Self.minimumContrast ? $0 : nil },
                fill: accent.flatMap { $0.contrastRatio(with: .white) >= Self.minimumContrast ? $0 : nil })
        }
        self.colors = colors
        terminal = Self.terminal(config.tokens(for: .dark))
    }

    public func app(_ appearance: ThemeAppearance) -> AppThemeColors { colors[appearance] ?? AppThemeColors() }

    /// 背景與文字都要有、且對比夠，否則整組退回系統終端機配色;ANSI 文字色逐格檢查。
    static func terminal(_ tokens: [String: ThemeColor]) -> TerminalTheme? {
        guard let background = tokens["panel_bg"], let foreground = tokens["text"],
              foreground.contrastRatio(with: background) >= minimumContrast
        else { return nil }
        func text(_ token: String) -> ThemeColor? {
            tokens[token].flatMap { $0.contrastRatio(with: background) >= minimumContrast ? $0 : nil }
        }
        // 0 黑、8 亮黑是接近背景的顏色，本來就不承載一般文字，不檢查。
        let colors = ["red", "green", "yellow", "blue", "mauve", "teal"].map(text)
        let ansi: [ThemeColor?] = [tokens["surface1"]] + colors + [text("subtext0")] + [tokens["overlay0"]] + colors + [foreground]
        let cursor = tokens["accent"].flatMap { $0.contrastRatio(with: background) >= minimumGraphicContrast ? $0 : nil }
        return TerminalTheme(background: background, foreground: foreground, ansi: ansi, cursor: cursor)
    }
}

/// herdr 內建主題的顏色。
///
/// herdr 文件只列了主題名稱，沒有色碼;這裡用各配色方案公開的官方色票(Catppuccin、Tokyo Night、Gruvbox、Dracula、Nord),
/// token 對應是我們自己的對照，可能與 herdr 畫面上的略有差異。其他內建主題(one-dark、solarized、kanagawa、rose-pine、
/// vesper、terminal)沒有對照表：只套用 `[theme.custom]` 寫明的顏色，其餘用系統配色。
enum HerdrPalette {
    static let resetAliases: Set<String> = ["reset", "default", "none", "transparent"]
    static let lightSibling = ["catppuccin": "catppuccin-latte", "tokyo-night": "tokyo-night-day", "gruvbox": "gruvbox-light"]
    static let darkSibling = ["catppuccin-latte": "catppuccin", "tokyo-night-day": "tokyo-night", "gruvbox-light": "gruvbox"]

    private static func palette(_ hex: [String: String]) -> [String: ThemeColor] {
        hex.mapValues { ThemeColor(hex: $0)! }
    }

    static let builtIn: [String: [String: ThemeColor]] = [
        "catppuccin": palette([
            "panel_bg": "#1e1e2e", "surface0": "#313244", "surface1": "#45475a", "overlay0": "#6c7086", "overlay1": "#7f849c",
            "text": "#cdd6f4", "subtext0": "#a6adc8", "accent": "#cba6f7", "mauve": "#cba6f7", "green": "#a6e3a1",
            "yellow": "#f9e2af", "red": "#f38ba8", "blue": "#89b4fa", "teal": "#94e2d5", "peach": "#fab387",
        ]),
        "catppuccin-latte": palette([
            "panel_bg": "#eff1f5", "surface0": "#ccd0da", "surface1": "#bcc0cc", "overlay0": "#9ca0b0", "overlay1": "#8c8fa1",
            "text": "#4c4f69", "subtext0": "#6c6f85", "accent": "#8839ef", "mauve": "#8839ef", "green": "#40a02b",
            "yellow": "#df8e1d", "red": "#d20f39", "blue": "#1e66f5", "teal": "#179299", "peach": "#fe640b",
        ]),
        "tokyo-night": palette([
            "panel_bg": "#1a1b26", "surface0": "#292e42", "surface1": "#414868", "overlay0": "#565f89", "overlay1": "#737aa2",
            "text": "#c0caf5", "subtext0": "#a9b1d6", "accent": "#7aa2f7", "mauve": "#bb9af7", "green": "#9ece6a",
            "yellow": "#e0af68", "red": "#f7768e", "blue": "#7aa2f7", "teal": "#7dcfff", "peach": "#ff9e64",
        ]),
        "tokyo-night-day": palette([
            "panel_bg": "#e1e2e7", "surface0": "#c4c8da", "surface1": "#a8aecb", "overlay0": "#848cb5", "overlay1": "#68709a",
            "text": "#3760bf", "subtext0": "#6172b0", "accent": "#2e7de9", "mauve": "#9854f1", "green": "#587539",
            "yellow": "#8c6c3e", "red": "#f52a65", "blue": "#2e7de9", "teal": "#007197", "peach": "#b15c00",
        ]),
        "gruvbox": palette([
            "panel_bg": "#282828", "surface0": "#3c3836", "surface1": "#504945", "overlay0": "#928374", "overlay1": "#a89984",
            "text": "#ebdbb2", "subtext0": "#d5c4a1", "accent": "#fe8019", "mauve": "#d3869b", "green": "#b8bb26",
            "yellow": "#fabd2f", "red": "#fb4934", "blue": "#83a598", "teal": "#8ec07c", "peach": "#fe8019",
        ]),
        "gruvbox-light": palette([
            "panel_bg": "#fbf1c7", "surface0": "#ebdbb2", "surface1": "#d5c4a1", "overlay0": "#928374", "overlay1": "#7c6f64",
            "text": "#3c3836", "subtext0": "#504945", "accent": "#af3a03", "mauve": "#8f3f71", "green": "#79740e",
            "yellow": "#b57614", "red": "#9d0006", "blue": "#076678", "teal": "#427b58", "peach": "#af3a03",
        ]),
        "dracula": palette([
            "panel_bg": "#282a36", "surface0": "#343746", "surface1": "#44475a", "overlay0": "#6272a4", "overlay1": "#7b88b8",
            "text": "#f8f8f2", "subtext0": "#e2e2dc", "accent": "#bd93f9", "mauve": "#bd93f9", "green": "#50fa7b",
            "yellow": "#f1fa8c", "red": "#ff5555", "blue": "#8be9fd", "teal": "#8be9fd", "peach": "#ffb86c",
        ]),
        "nord": palette([
            "panel_bg": "#2e3440", "surface0": "#3b4252", "surface1": "#434c5e", "overlay0": "#4c566a", "overlay1": "#616e88",
            "text": "#eceff4", "subtext0": "#d8dee9", "accent": "#88c0d0", "mauve": "#b48ead", "green": "#a3be8c",
            "yellow": "#ebcb8b", "red": "#bf616a", "blue": "#81a1c1", "teal": "#8fbcbb", "peach": "#d08770",
        ]),
    ]
}
