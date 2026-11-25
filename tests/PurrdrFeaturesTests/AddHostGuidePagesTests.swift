import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 新增主機引導每一步是一頁 push(#622、spec #612):`pages` 是畫面上疊著的頁(一步一頁),系統返回鈕與左緣滑回
/// 對應 `back()`;完成頁沒有上一步,但前面疊著的頁仍在。
@MainActor
@Suite("新增主機引導的頁疊")
struct AddHostGuidePagesTests {
    @Test("第一頁只有一頁;選擇往前疊一頁，返回少一頁")
    func pagesFollowSteps() {
        let model = AddHostGuideModelTests.model()
        #expect(model.pages == [.kind])
        model.choose(.ssh)
        #expect(model.pages == [.kind, .system])
        model.choose(.macOS)
        #expect(model.pages == [.kind, .system, .sshMethod])
        model.back()
        #expect(model.pages == [.kind, .system])
        model.back()
        #expect(model.pages == [.kind])
    }

    @Test("儲存後到完成頁:前面的頁還在、完成頁不能返回")
    func finishedKeepsEarlierPages() async throws {
        let model = AddHostGuideModelTests.model(factory: ChannelFactory(await HostEditorModelTests.healthyHost()))
        AddHostGuideModelTests.atDetails(model)
        await model.testConnection()
        let before = model.pages
        #expect(before.last == .test)
        _ = try #require(model.save())
        #expect(model.pages == before + [.finished])
        #expect(!model.canGoBack)
    }
}
