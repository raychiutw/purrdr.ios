import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

@testable import PurrdrFeatures

/// 聊天標題膠囊(#476):單行 44pt,狀態點、Tab 名稱、模式;內容由 model 產生。
@MainActor
@Suite("聊天標題膠囊")
struct ConversationTitleCapsuleTests {
    @Test("名稱是 Tab 名稱;沒有 Tab 名稱(還沒讀到 snapshot)退回 Workspace 名稱")
    func capsuleName() {
        #expect(ConversationHeader(title: "ledger", status: .online, segments: [], tabName: "整理帳本").capsuleName == "整理帳本")
        #expect(ConversationHeader(title: "ledger", status: .online, segments: []).capsuleName == "ledger")
        #expect(ConversationHeader(title: "ledger", status: .online, segments: [], tabName: "").capsuleName == "ledger")
    }

    @Test("狀態點:需要你橘、工作中主色、其他灰")
    func dotTone() {
        func tone(_ status: ConversationHeader.Status) -> StatusTone { status.tone }
        #expect(tone(.needsYou) == .attention)
        #expect(tone(.working) == .accent)
        #expect(tone(.done) == .neutral)
        #expect(tone(.online) == .neutral)
        #expect(tone(.offline) == .neutral)
    }

    @Test("模式:一般與讀不到不顯示;其他顯示名稱;略過權限是警示(保留橘色盾牌)")
    func modeBadge() {
        func badge(_ mode: AgentPermissionMode?) -> ConversationHeader.PermissionBadge? {
            ConversationHeader(title: "t", status: .working, segments: [], permissionMode: mode).permissionBadge
        }
        #expect(badge(nil) == nil)
        #expect(badge(.normal) == nil)
        #expect(badge(.auto)?.isWarning == false)
        #expect(badge(.bypassPermissions)?.isWarning == true)
    }

    @Test("無障礙標籤:Tab 名稱、模式、狀態、主機,不靠顏色")
    func accessibility() {
        let header = ConversationHeader(
            title: "ledger", status: .needsYou, segments: ["studio"], permissionMode: .plan, tabName: "整理帳本")
        #expect(header.accessibilityText == "整理帳本, Plan, Needs You, studio")
    }

    @Test("長名稱不改變 model 內容(截斷是畫面的事),模式文字仍完整")
    func longNameKeepsMode() {
        let long = String(repeating: "很長的名稱", count: 20)
        let header = ConversationHeader(title: "t", status: .working, segments: [], permissionMode: .acceptEdits, tabName: long)
        #expect(header.capsuleName == long)
        #expect(header.permissionBadge?.mode.displayName == "Accept Edits")
    }

    @Test("poll 後標題帶 snapshot 的 Tab 名稱:預設數字名稱是「Tab N」(N 是在 workspace 裡的順序)")
    func modelHeaderCarriesTabName() async throws {
        let setup = try ConversationHeaderTests.setup()
        await setup.host.bridge.expect(ConversationHeaderTests.bridge, reply: ConversationHeaderTests.snapshot(status: "idle"))
        await setup.model.poll()
        #expect(setup.model.header.tabName == "Tab 1")
        #expect(setup.model.header.capsuleName == "Tab 1")
    }

    @Test("標題的狀態點與停止列的圓點共用同一個尺寸:8pt")
    func dotSharesStopBarSize() {
        #expect(StatusDot.diameter == 8)
    }
}
