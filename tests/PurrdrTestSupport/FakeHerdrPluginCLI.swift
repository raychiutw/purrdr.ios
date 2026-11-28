import Foundation

#if os(macOS)

/// 假的 `herdr` 執行檔(只有 `plugin list/install/uninstall/update`),裝在 `LocalShellHost` 家目錄的 `bin/herdr`。
///
/// `HerdrCommand` 的 PATH 前綴先找 `$HOME/bin`,所以推播的主機端會叫到它，不碰真的 herdr。
/// 它把收到的參數記在 `fake/herdr-calls`;`fake/installed` 存在代表「herdr 已安裝 purrdr.push」;
/// `fake/install-fails` 存在時 `plugin install` 失敗(stderr「git clone failed」)。
/// `fake/version` 是已安裝的外掛版本(沒有檔案時 0.1.0);`plugin update` 把它改成 0.3.0,`fake/update-fails` 存在時失敗。
public enum FakeHerdrPluginCLI {
    public static let script = """
        #!/bin/sh
        mkdir -p "$HOME/fake"
        printf '%s\\n' "$*" >> "$HOME/fake/herdr-calls"
        case "$*" in
          "plugin list --plugin purrdr.push --json")
            if [ -f "$HOME/fake/installed" ]; then
              printf '%s\\n' '{"id":"cli:plugin","result":{"plugins":[{"plugin_id":"purrdr.push","name":"Purrdr Push","version":"'"$(cat "$HOME/fake/version" 2>/dev/null || echo 0.1.0)"'","enabled":true}],"type":"plugin_list"}}'
            else
              printf '%s\\n' '{"id":"cli:plugin","result":{"plugins":[],"type":"plugin_list"}}'
            fi ;;
          "plugin install raychiutw/purrdr.host/host-plugin --yes")
            if [ -f "$HOME/fake/install-fails" ]; then echo "git clone failed" >&2; exit 1; fi
            : > "$HOME/fake/installed" ;;
          "plugin update purrdr.push --yes")
            if [ -f "$HOME/fake/update-fails" ]; then echo "git fetch failed" >&2; exit 1; fi
            printf '%s\\n' 0.3.0 > "$HOME/fake/version" ;;
          "plugin uninstall purrdr.push") rm -f "$HOME/fake/installed" ;;
          *) echo "unexpected: $*" >&2; exit 2 ;;
        esac

        """

    /// 裝到 `host` 的 `bin/herdr`。
    public static func install(on host: LocalShellHost) throws {
        let url = try host.write(Data(script.utf8), to: "bin/herdr")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// 假 herdr 目前回報的外掛版本。
    public static func pluginVersion(on host: LocalShellHost) -> String {
        (try? String(contentsOf: host.url("fake/version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
    }

    public static func isPluginInstalled(on host: LocalShellHost) -> Bool {
        FileManager.default.fileExists(atPath: host.url("fake/installed").path)
    }

    public static func calls(on host: LocalShellHost) throws -> [String] {
        let url = host.url("fake/herdr-calls")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// 家目錄的樣子，不含假 herdr 自己的紀錄(`fake/`)。
    public static func snapshot(of host: LocalShellHost) throws -> DirectorySnapshot {
        var snapshot = try DirectorySnapshot(of: host.home)
        snapshot.entries = snapshot.entries.filter { !$0.key.hasPrefix("fake") }
        return snapshot
    }
}

#endif
