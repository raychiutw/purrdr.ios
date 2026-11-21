import Foundation
import PurrdrCore

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
/// Windows 主機(#68)的 herdr 設定在 `%APPDATA%\herdr\config.toml`(預設是 `<家目錄>\AppData\Roaming`;被重新導向
/// 的 `%APPDATA%` 不支援)。兩個位置在同一次往返一起讀，依主機回報的家目錄(`HostFileRead.isWindows`)選一個。
///
/// 不讀 herdrchat 的主題檔(#2 Out of Scope)。
public struct HostThemeHost: Sendable {
    public static let configPath: HostPath = ".config/herdr/config.toml"
    /// Windows 的 herdr 設定(`%APPDATA%\herdr\config.toml`)。
    public static let windowsConfigPath: HostPath = "AppData/Roaming/herdr/config.toml"
    public static let feature = HostWriteFeature(id: "theme", userFiles: [])
    public static let referencePath = feature.ownFile("README.md")

    let write: ReversibleHostWrite
    let files: HostFiles

    /// - Parameter files: 讀主題用的主機檔案(每台主機共用長駐讀取的那份);`nil` 時每次讀是一次性指令。
    public init(channel: any HostChannel, files: HostFiles? = nil) {
        write = ReversibleHostWrite(channel: channel, feature: Self.feature)
        self.files = .shared(files, channel: channel)
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

    /// 條件式讀主題(沒有已知版本時一定讀):`config.toml` 與 `known` 版本相同時是 `.unchanged`。
    /// 沒有 `config.toml`(或沒有 `~/.config/herdr`)= herdr 預設主題。
    public func readTheme(ifChangedFrom known: HostFileVersion?) async throws -> HostFileUpdate<HostTheme> {
        // 兩個位置帶同一個已知版本：作業系統要讀完才知道，不是這台的那個位置不存在，回 missing 也很小。
        let paths = [Self.configPath, Self.windowsConfigPath]
        let read = try await files.read(paths, knownVersions: known.map { version in Dictionary(uniqueKeysWithValues: paths.map { ($0, version) }) } ?? [:])
        let path = read.isWindows ? Self.windowsConfigPath : Self.configPath
        if read.unchanged.contains(path) { return .unchanged }
        switch read[path] ?? .missing {
        case .missing, .missingDirectory:
            return .changed(HostTheme(config: HerdrThemeConfig(toml: nil)), version: nil)
        case .file(let data, let version):
            return .changed(HostTheme(config: HerdrThemeConfig(toml: String(decoding: data, as: UTF8.self))), version: version)
        case .notRegularFile, .unreadable, .tooLarge:
            throw HostWriteError.unusableFile(path)
        }
    }

    /// 主題參考檔(英文，給主機上的人與 agent 看)。
    static let reference = """
        # Purrdr host theme

        Purrdr (the iPhone and iPad app for herdr) colors its chat and terminal with this
        host's herdr theme. This file was added by Purrdr when you turned on "Use Host Theme";
        turning it off in Purrdr removes this folder. Purrdr never changes config.toml.

        ## Where the colors come from

        Purrdr reads `[theme]` in ~/.config/herdr/config.toml (on Windows,
        %APPDATA%\\herdr\\config.toml), the same file herdr uses:

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
