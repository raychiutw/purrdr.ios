import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 頂部橫幅的內容(#530):由「需要你通知」的橫幅加上列表的 workspace、Agent 種類與最後一段訊息組成。
@MainActor
@Suite("需要你橫幅內容")
struct NeedsYouBannerContentTests {
    static let studio = AgentListHostFilterTests.studio

    static func blockedModel() async -> MergedAgentListModel {
        await AgentListHostFilterTests.loadedModel { SnapshotEdit.agent("w1:pB", in: &$0) { $0["agent_status"] = "blocked" } }
    }

    @Test("轉變出現橫幅:帶那個聊天的 workspace、Agent 種類、最後一段訊息與總數")
    func contentForTransition() async {
        let merged = await Self.blockedModel()
        let route = ChatRoute(host: Self.studio, paneID: "w1:pB")
        merged.list(for: Self.studio)?.previews["w1:pB"] = MessagePreview(text: "Allow the build?", date: nil, isFromUser: false)
        // 先看到沒有需要你的快照,再變成需要你。
        merged.needsYou.apply(.init(hosts: [.init(host: Self.studio, blocked: [])], current: []))
        merged.needsYou.apply(merged.needsYouInput)

        let content = merged.needsYouBanner

        #expect(content?.route == route)
        #expect(content?.total == 1)
        #expect(content?.message == "Allow the build?")
        #expect(content?.workspace.isEmpty == false)
        #expect(content?.kind.isEmpty == false)
    }

    @Test("沒有橫幅(第一次快照就需要你)時沒有內容")
    func noBannerNoContent() async {
        let merged = await Self.blockedModel()
        merged.needsYou.apply(merged.needsYouInput)
        #expect(merged.needsYouBanner == nil)
    }

    @Test("所在列已不在列表上時沒有內容,不當掉")
    func missingRowYieldsNil() async {
        let merged = await Self.blockedModel()
        merged.needsYou.apply(.init(hosts: [.init(host: Self.studio, blocked: [])], current: []))
        merged.needsYou.apply(.init(hosts: [.init(host: Self.studio, blocked: [.init(paneID: "w9:p9", isMuted: false)])], current: []))
        #expect(merged.needsYou.banner != nil)
        #expect(merged.needsYouBanner == nil)
    }
}
