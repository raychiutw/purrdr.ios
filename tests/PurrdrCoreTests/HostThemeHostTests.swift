#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機主題的主機端(#23,ADR-0002):讀 `~/.config/herdr/config.toml`;經同意後寫主題參考檔
/// `~/.purrdr/theme/README.md`,關閉時還原。在本機用真的 `/bin/sh` 跑，家目錄是暫存資料夾。
@Suite("主機主題(主機)")
struct HostThemeHostTests {
    let host: LocalShellHost
    let theme: HostThemeHost

    init() throws {
        host = try LocalShellHost.temporary()
        theme = HostThemeHost(channel: host)
    }

    @Test("沒有 config.toml:用 herdr 預設主題")
    func missingConfig() async throws {
        #expect(try await theme.readTheme(ifChangedFrom: nil).requireChanged().name == "catppuccin")
    }

    @Test("讀主機 herdr 的 config.toml")
    func readsConfig() async throws {
        _ = try host.write(Data("[theme]\nname = \"dracula\"\n".utf8), to: ".config/herdr/config.toml")
        let read = try await theme.readTheme(ifChangedFrom: nil).requireChanged()
        #expect(read.name == "dracula")
        #expect(read.terminal?.background == ThemeColor(hex: "#282a36"))
    }

    @Test("config.toml 不是一般檔案：丟錯，不卡住")
    func notRegularFile() async throws {
        try FileManager.default.createDirectory(at: host.url(".config/herdr/config.toml"), withIntermediateDirectories: true)
        await #expect(throws: HostWriteError.unusableFile(HostThemeHost.configPath)) { try await theme.readTheme(ifChangedFrom: nil).requireChanged() }
    }

    @Test("同意後寫參考檔(不動 config.toml);關閉後家目錄與同意前完全相同")
    func installAndRestore() async throws {
        _ = try host.write(Data("[theme]\nname = \"nord\"\n".utf8), to: ".config/herdr/config.toml")
        let before = try DirectorySnapshot(of: host.home)
        #expect(try await theme.inspect().user == NSUserName())
        #expect(try await theme.inspect().isInstalled == false)

        try await theme.install()
        let reference = try String(contentsOf: host.url(".purrdr/theme/README.md"), encoding: .utf8)
        #expect(reference.contains("[theme.custom]"))
        #expect(reference.contains("4.5:1"))
        #expect(try String(contentsOf: host.url(".config/herdr/config.toml"), encoding: .utf8) == "[theme]\nname = \"nord\"\n")
        #expect(try await theme.inspect().isInstalled)

        try await theme.restore()
        #expect(try DirectorySnapshot(of: host.home) == before)
    }
}
#endif
