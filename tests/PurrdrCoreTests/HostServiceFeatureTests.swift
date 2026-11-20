import PurrdrCore
import Testing

/// 依主機服務版本啟用的功能(#283):門檻只登記在 `HostServiceFeature.minimumVersion`。
@Suite("主機服務版本門檻")
struct HostServiceFeatureTests {
    @Test("版本依數字比較，缺的段補 0、預發行標記不比")
    func versionsCompareNumerically() throws {
        let tenth = try #require(HostServiceVersion("0.10.0"))
        let ninth = try #require(HostServiceVersion("0.9.9"))

        #expect(ninth < tenth)
        #expect(HostServiceVersion("1.2") == HostServiceVersion("1.2.0"))
        #expect(HostServiceVersion("0.4.0-beta.1") == HostServiceVersion("0.4.0"))
        #expect(tenth.description == "0.10.0")
    }

    @Test("看不懂的版本字串讀成 nil")
    func unreadableVersionsAreNil() {
        for text in ["", "abc", "1.x.0", "1.2.3.4", "1..2"] {
            #expect(HostServiceVersion(text) == nil, "\(text)")
        }
    }

    @Test("主機取檔從主機服務 0.4.0 起可用;更舊、沒回報或看不懂的版本不可用")
    func fileFetchStartsAtZeroFourZero() {
        #expect(HostServiceFeature.fileFetch.minimumVersion == HostServiceVersion("0.4.0"))
        #expect(HostServiceFeature.fileFetch.isAvailable(onHostServiceVersion: "0.4.0"))
        #expect(HostServiceFeature.fileFetch.isAvailable(onHostServiceVersion: "0.10.0"))
        #expect(!HostServiceFeature.fileFetch.isAvailable(onHostServiceVersion: "0.3.9"))
        #expect(!HostServiceFeature.fileFetch.isAvailable(onHostServiceVersion: nil))
        #expect(!HostServiceFeature.fileFetch.isAvailable(onHostServiceVersion: "unknown"))
    }

    @Test("上傳圖片與檔案從主機服務 0.7.0 起可用(#288)")
    func fileUploadStartsAtZeroSevenZero() {
        #expect(HostServiceFeature.fileUpload.isAvailable(onHostServiceVersion: "0.7.0"))
        #expect(!HostServiceFeature.fileUpload.isAvailable(onHostServiceVersion: "0.6.9"))
    }

    @Test("列表預覽與 subagent／workflow／委派讀取從主機服務 0.7.0 起可用")
    func transcriptPreviewsAndDelegationsStartAtZeroSevenZero() {
        #expect(HostServiceFeature.transcriptPreviewsAndDelegations.minimumVersion == HostServiceVersion("0.7.0"))
        #expect(HostServiceFeature.transcriptPreviewsAndDelegations.isAvailable(onHostServiceVersion: "0.7.0"))
        #expect(!HostServiceFeature.transcriptPreviewsAndDelegations.isAvailable(onHostServiceVersion: "0.6.9"))
    }

    @Test("主機服務代裝推播外掛從 0.6.0 起可用;相同或更新的版本才算", arguments: [
        ("0.6.0", true), ("0.6.1", true), ("1.0", true), ("0.10.0", true), ("0.6.0-beta.1", true),
        ("0.5.9", false), ("0.5", false),
    ])
    func pushPluginStartsAtZeroSixZero(_ installed: String, _ supported: Bool) {
        #expect(HostServiceFeature.pushPlugin.minimumVersion == HostServiceVersion(0, 6, 0))
        #expect(HostServiceFeature.pushPlugin.isAvailable(onHostServiceVersion: installed) == supported)
    }

    @Test("看不懂的版本一律視為沒有推播外掛代裝", arguments: ["", "garbage", "0.x.0", "1.2.3.4", "..", "v0.6.0"])
    func unreadableVersionHasNoPushPlugin(_ installed: String) {
        #expect(!HostServiceFeature.pushPlugin.isAvailable(onHostServiceVersion: installed))
    }
}
