import Foundation

/// 從真實主機錄下的回應(`scripts/record-herdr-fixture.sh`,說明見 `Fixtures/README.md`)。
public enum Fixtures {
    public static let defaultHerdrVersion = "0.9.5"

    /// 讀一份錄製檔的原始 bytes。找不到就直接當掉：測試寫錯檔名要立刻看到。
    public static func data(_ name: String, herdr version: String = defaultHerdrVersion) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/herdr-\(version)"),
              let data = try? Data(contentsOf: url) else {
            fatalError("找不到錄製檔 Fixtures/herdr-\(version)/\(name)")
        }
        return data
    }

    /// `herdr terminal session control`／`observe` 的錄製檔(`Fixtures/herdr-<版本>/session-control/<名稱>`,#4 spike)。
    public static func sessionControl(_ name: String, herdr version: String = defaultHerdrVersion) -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures/herdr-\(version)/session-control"
        ), let data = try? Data(contentsOf: url) else {
            fatalError("找不到錄製檔 Fixtures/herdr-\(version)/session-control/\(name)")
        }
        return data
    }

    /// 錄製檔逐行切開(不含換行)。
    public static func sessionControlLines(_ name: String, herdr version: String = defaultHerdrVersion) -> [Data] {
        sessionControl(name, herdr: version).split(separator: 0x0A).map { Data($0) }
    }
}
