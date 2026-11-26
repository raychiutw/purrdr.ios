import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

@testable import PurrdrFeatures

/// 聊天標題膠囊(#476):系統標題(Tab 名稱)與副標題(狀態);內容由 model 產生(#618)。
@MainActor
@Suite("聊天標題膠囊")
struct ConversationTitleCapsuleTests {
    @Test("名稱是 Tab 名稱;沒有 Tab 名稱(還沒讀到 snapshot)退回 Workspace 名稱")
    func capsuleName() {
        #expect(ConversationHeader(title: "ledger", status: .online, segments: [], tabName: "整理帳本").capsuleName == "整理帳本")
        #expect(ConversationHeader(title: "ledger", status: .online, segments: []).capsuleName == "ledger")
        #expect(ConversationHeader(title: "ledger", status: .online, segments: [], tabName: "").capsuleName == "ledger")
    }

    @Test("副標題只有狀態文字,不含主機名稱(#618 使用者定案:標題 = Tab 名稱,副標題 = 狀態)")
    func subtitle() {
        #expect(ConversationHeader(title: "ledger", status: .working, segments: ["Studio Mac"]).subtitle == "Working")
        #expect(ConversationHeader(title: "t", status: .offline, segments: []).subtitle == "Reconnecting…")
        #expect(ConversationHeader(title: "t", status: .online, segments: ["Studio Mac", "Build Box"]).subtitle == "Online")
        #expect(ConversationHeader(title: "t", status: .done, segments: [""]).subtitle == "Done")
    }

    @Test("副標題不帶權限模式(權限模式在「⋯」與面板裡)")
    func subtitleHasNoPermissionMode() {
        let header = ConversationHeader(title: "t", status: .working, segments: ["Studio Mac"])
        #expect(!header.subtitle.contains("Plan"))
    }

    @Test("poll 後標題帶 snapshot 的 Tab 名稱:預設數字名稱是「Tab N」(N 是在 workspace 裡的順序)")
    func modelHeaderCarriesTabName() async throws {
        let setup = try ConversationHeaderTests.setup()
        await setup.host.bridge.expect(ConversationHeaderTests.bridge, reply: ConversationHeaderTests.snapshot(status: "idle"))
        await setup.model.poll()
        #expect(setup.model.header.tabName == "Tab 1")
        #expect(setup.model.header.capsuleName == "Tab 1")
    }
}
