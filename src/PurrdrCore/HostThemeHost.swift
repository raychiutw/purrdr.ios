import Foundation

/// 同意前的檢查結果。
public struct HostThemeInspection: Equatable, Sendable {
    /// 會以這個主機使用者寫入參考檔。
    public var user: String
    public var isInstalled: Bool

    public init(user: String, isInstalled: Bool) {
        self.user = user
        self.isInstalled = isInstalled
    }
}

/// 主機主題的主機端(#23;ADR-0002 的寫入例外)。
///
/// - 讀：主機 herdr 的 `~/.config/herdr/config.toml`(herdr 文件的 Linux／macOS 路徑)的 `[theme]`。只讀，不改它。
/// - 寫：經使用者同意後放一份主題參考檔 `~/.purrdr/theme/README.md`,說明 Purrdr 用了 herdr 主題的哪些 token、
///   對比規則，讓使用者或 agent 改 herdr 主題時有依據。關閉時經 `ReversibleHostWrite` 移除，主機與同意前完全相同。
///
/// 不讀 herdrchat 的主題檔(#2 Out of Scope)。Windows 的 `%APPDATA%\herdr\config.toml` 還沒做(主機檔案只有 POSIX)。
public struct HostThemeHost: Sendable {
    public static let configPath: HostPath = ".config/herdr/config.toml"
    public static let feature = HostWriteFeature(id: "theme", userFiles: [])
    public static let referencePath = feature.ownFile("README.md")

    let write: ReversibleHostWrite
    let files: HostFiles

    public init(channel: any HostChannel) {
        write = ReversibleHostWrite(channel: channel, feature: Self.feature)
        files = HostFiles(channel: channel)
    }

    public func inspect() async throws -> HostThemeInspection {
        let inspection = try await write.inspect()
        return HostThemeInspection(user: inspection.read.user, isInstalled: inspection.isInstalled)
    }

    /// 寫入主題參考檔。
    public func install() async throws {
        try await write.install { _ in
            HostWritePlan(userFiles: [:], ownFiles: ["README.md": .init(Data(Self.reference.utf8))])
        }
    }

    /// 移除 `~/.purrdr/theme/`。
    public func restore() async throws {
        try await write.restore { _, current, _ in current }
    }

    /// 讀主機 herdr 的主題。沒有 `config.toml`(或沒有 `~/.config/herdr`)= herdr 預設主題。
    public func readTheme() async throws -> HostTheme {
        let read = try await files.read([Self.configPath])
        switch read[Self.configPath] ?? .missing {
        case .missing, .missingDirectory:
            return HostTheme(config: HerdrThemeConfig(toml: nil))
        case .file(let data, _):
            return HostTheme(config: HerdrThemeConfig(toml: String(decoding: data, as: UTF8.self)))
        case .notRegularFile, .unreadable, .tooLarge:
            throw HostWriteError.unusableFile(Self.configPath)
        }
    }

    /// 主題參考檔(英文，給主機上的人與 agent 看)。
    static let reference = """
        # Purrdr host theme

        Purrdr (the iPhone and iPad app for herdr) colors its chat and terminal with this
        host's herdr theme. This file was added by Purrdr when you turned on "Use Host Theme";
        turning it off in Purrdr removes this folder. Purrdr never changes config.toml.

        ## Where the colors come from

        Purrdr reads `[theme]` in ~/.config/herdr/config.toml, the same file herdr uses:

        ```toml
        [theme]
        name = "catppuccin"          # built-in theme
        auto_switch = true           # optional: light_name / dark_name follow iOS appearance
        light_name = "catppuccin-latte"

        [theme.custom]
        accent = "#cba6f7"           # app tint, links, your message bubbles, terminal cursor
        panel_bg = "#1e1e2e"         # terminal background
        text = "#cdd6f4"             # terminal text
        red = "#f38ba8"              # terminal ANSI colors: red, green, yellow, blue,
                                     # mauve (magenta), teal (cyan), subtext0 (white)

        [theme.custom.light]         # used only with auto_switch = true
        [theme.custom.dark]
        ```

        Colors may be #rgb, #rrggbb, rgb(r, g, b), or a basic color name.

        ## Contrast

        Every text color must reach a 4.5:1 contrast ratio against what it sits on;
        otherwise Purrdr drops it and uses the system color instead:

        - accent as text: against #F2F2F7 (light) and #1C1C1E (dark)
        - accent as a fill: white text on it
        - terminal text and ANSI colors: against panel_bg

        """
}
