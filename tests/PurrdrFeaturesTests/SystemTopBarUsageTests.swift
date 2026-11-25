import Foundation
import Testing

/// 第一階頂列一律用系統元件(#615、spec #612):不隱藏系統導覽列改自繪頂列,不自畫漸層遮罩、搜尋欄或膠囊,
/// 工具列項目不自加寬度。守門原始碼,擋這些做法長回來。
@Suite("系統頂列用法")
struct SystemTopBarUsageTests {
    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    static var featureFiles: [(name: String, text: String)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: featuresFolder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } }
    }

    @Test("不隱藏系統導覽列(toolbarVisibility(.hidden, for: .navigationBar))")
    func neverHidesNavigationBar() {
        let files = Self.featureFiles
        #expect(files.count > 10, "找不到 src/PurrdrFeatures 的原始碼")
        for (name, text) in files {
            let hidden = text.contains(".toolbarVisibility(.hidden, for: .navigationBar)") || text.contains(".toolbar(.hidden, for: .navigationBar)")
            #expect(!hidden, "\(name) 隱藏了系統導覽列;頂列要用系統的 navigationTitle／toolbar／searchable")
        }
    }

    @Test("頂列檔案不自畫:沒有漸層遮罩、捲動量測、floatingGlass 膠囊、自畫搜尋欄、自訂寬度")
    func topBarFileDrawsNothing() throws {
        let text = try String(contentsOf: Self.featuresFolder.appending(path: "TopBarViews.swift"), encoding: .utf8)
        for pattern in ["LinearGradient", "onScrollGeometryChange", "floatingGlass", "TextField(", "Capsule()", ".frame(width:", ".frame(minWidth:"] {
            #expect(!text.contains(pattern), "TopBarViews.swift 不該自己畫頂列(\(pattern));交給系統")
        }
        #expect(text.contains(".searchable("), "頂列搜尋要用系統 searchable")
        #expect(text.contains("ToolbarItemGroup"), "電腦圖示與＋要放同一個 ToolbarItemGroup 讓系統合成膠囊")
        #expect(text.contains("ToolbarSpacer"), "頭像要用 ToolbarSpacer 與膠囊隔開")
    }
}
