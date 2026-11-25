import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 圖片自動解碼只限常見格式(#579):以內容判斷，其他格式要使用者點擊。
@Suite("主機取檔的圖片格式把關")
struct HostFileLoaderImageFormatTests {
    static let scope = HostFileLoaderTests.scope
    static let shot = HostFileLoaderTests.shot
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 7, count: 100))
    /// BMP:副檔名取 `.png` 也不能自動解碼。
    static let bitmap = Data("BM".utf8) + Data(repeating: 1, count: 100)

    @Test("不是常見格式的圖片不自動載入:回報大小，等使用者點擊")
    func uncommonFormatWaitsForTheClick() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Self.bitmap])
        let loader = HostFileLoader(fetcher: fetcher)

        let outcome = await loader.load(Self.shot, scope: Self.scope, automaticImageFormatsOnly: true)

        #expect(outcome == .overAutomaticLimit(size: Self.bitmap.count))
    }

    @Test("使用者點擊後不限格式照樣載入")
    func clickLoadsAnyFormat() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Self.bitmap])
        let loader = HostFileLoader(fetcher: fetcher)
        _ = await loader.load(Self.shot, scope: Self.scope, automaticImageFormatsOnly: true)

        guard case .loaded(let data, _) = await loader.load(Self.shot, scope: Self.scope, userRequested: true, automaticImageFormatsOnly: true) else {
            Issue.record("點擊後沒有載入"); return
        }
        #expect(data == Self.bitmap)
    }

    @Test("常見格式行為不變:自動載入完整內容")
    func commonFormatLoadsAutomatically() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Self.png])
        let loader = HostFileLoader(fetcher: fetcher)

        guard case .loaded(let data, _) = await loader.load(Self.shot, scope: Self.scope, automaticImageFormatsOnly: true) else {
            Issue.record("沒有自動載入"); return
        }
        #expect(data == Self.png)
    }

    @Test("沒有要求格式把關的呼叫(PDF 縮圖等)不受影響")
    func ungatedCallersAreUnchanged() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Self.bitmap])
        let loader = HostFileLoader(fetcher: fetcher)

        guard case .loaded = await loader.load(Self.shot, scope: Self.scope) else { Issue.record("沒有載入"); return }
    }

    @Test("點擊載入過的檔案再顯示時直接用快取，不用再點")
    func clickedFileStaysLoaded() async {
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Self.bitmap])
        let loader = HostFileLoader(fetcher: fetcher)
        _ = await loader.load(Self.shot, scope: Self.scope, userRequested: true, automaticImageFormatsOnly: true)

        guard case .loaded = await loader.load(Self.shot, scope: Self.scope, automaticImageFormatsOnly: true) else { Issue.record("快取沒用上"); return }
    }
}
