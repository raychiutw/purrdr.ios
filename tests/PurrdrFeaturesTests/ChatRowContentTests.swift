import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// 聊天列內容(#502,設計稿 A 寬鬆版):三行的組成與順序、「離開期間」小標籤的位置、狀態圓點的顏色與實心／空心。
@Suite("聊天列內容")
struct ChatRowContentTests {
    private static func tab(
        title: String = "Tab 2", contentTitle: String = "CSV 匯出", tabName: String? = "Tab 2", status: AgentStatus = .idle,
        agent: AgentRow? = nil
    ) -> SpacesTab {
        SpacesTab(
            host: .demo, key: "w1:t2", title: title, target: .pane(ChatRoute(host: .demo, paneID: "w1:p1")),
            avatar: .agent(kind: "claude", status: status), tabName: tabName, contentTitle: contentTitle, agent: agent)
    }

    private static func agent(
        preview: AgentRow.Preview = .message("好,已經改好了", fromYou: false), time: AgentRow.Time? = .now, away: Bool = false, turns: Int? = nil,
        percent: Int? = nil
    ) -> AgentRow {
        AgentRow(
            paneID: "w1:p1", title: "CSV 匯出", subtitle: "", preview: preview, time: time, status: .done, isAway: away, awayTurns: turns,
            progress: percent.map { AgentProgress(contextPercent: $0) })
    }

    @Test("第一行 Tab 名稱、第二行 session 標題、第三行預覽;右欄是時間與用量")
    func threeLines() {
        let content = ChatRowContent(tab: Self.tab(agent: Self.agent(percent: 64)))

        #expect(content.lines == [.title("Tab 2"), .detail(awayBadge: nil, sessionTitle: "CSV 匯出"), .preview("好,已經改好了")])
        #expect(content.time == .now)
        #expect(content.contextPercent == 64)
    }

    @Test("改過名的 Tab 與沒改名的版面一致:名稱(或編號)在上、session 標題在下")
    func namedAndUnnamedTabsHaveSameLayout() {
        let named = ChatRowContent(tab: Self.tab(title: "purrdr.ios", tabName: "purrdr.ios"))
        let numbered = ChatRowContent(tab: Self.tab(tabName: "Tab 2"))

        #expect(named.lines == [.title("purrdr.ios"), .detail(awayBadge: nil, sessionTitle: "CSV 匯出")])
        #expect(numbered.lines == [.title("Tab 2"), .detail(awayBadge: nil, sessionTitle: "CSV 匯出")])
    }

    @Test("session 標題與 Tab 名稱相同:省略第二行")
    func sameTitleOmitsSecondLine() {
        let content = ChatRowContent(tab: Self.tab(contentTitle: "發版", tabName: "發版"))

        #expect(content.lines == [.title("發版")])
    }

    @Test("沒有 Tab(pane 自成一列):第一行是內容標題,沒有第二行")
    func paneWithoutTab() {
        let content = ChatRowContent(tab: Self.tab(tabName: nil))

        #expect(content.lines == [.title("CSV 匯出")])
    }

    @Test("離開期間小標籤放第二行開頭,第一行不受影響")
    func awayBadgeLeadsSecondLine() {
        let content = ChatRowContent(tab: Self.tab(agent: Self.agent(away: true, turns: 1)))

        #expect(content.lines[0] == .title("Tab 2"))
        #expect(content.lines[1] == .detail(awayBadge: "While away · +1 turns", sessionTitle: "CSV 匯出"))
    }

    @Test("沒有 session 標題但離開期間:第二行只有小標籤")
    func awayBadgeWithoutSessionTitle() {
        let content = ChatRowContent(tab: Self.tab(contentTitle: "Tab 2", agent: Self.agent(away: true)))

        #expect(content.lines[1] == .detail(awayBadge: "While away", sessionTitle: nil))
    }

    @Test("沒有訊息、標題與名稱相同:只剩一行")
    func titleOnly() {
        let content = ChatRowContent(tab: Self.tab(contentTitle: "Tab 2", agent: Self.agent(preview: .none, time: nil)))

        #expect(content.lines == [.title("Tab 2")])
        #expect(content.time == nil)
        #expect(content.contextPercent == nil)
    }

    @Test("預覽:需要你、自己送出的、一般訊息")
    func previewText() {
        #expect(ChatRowContent.previewText(.needsInput) == "Waiting for your input")
        #expect(ChatRowContent.previewText(.message("好", fromYou: true)) == "You: 好")
        #expect(ChatRowContent.previewText(.message("好", fromYou: false)) == "好")
        #expect(ChatRowContent.previewText(.none) == nil)
    }

    @Test("終端機的 Tab:沒有狀態圓點、沒有時間與預覽")
    func terminalTab() {
        let tab = SpacesTab(
            host: .demo, key: "w2:t1", title: "zsh", target: .pane(ChatRoute(host: .demo, paneID: "w2:p1")), avatar: .terminal, tabName: "Tab 1",
            contentTitle: "zsh")
        let content = ChatRowContent(tab: tab)

        #expect(content.avatar == .terminal)
        #expect(content.statusDot == nil)
        #expect(content.lines == [.title("Tab 1"), .detail(awayBadge: nil, sessionTitle: "zsh")])
    }

    @Test("狀態圓點:需要你橘、工作中主色、其他灰;實心未讀、空心已讀")
    func statusDots() {
        #expect(AgentStatus.blocked.statusDot == AvatarStatusDot(tone: .attention, isFilled: true))
        #expect(AgentStatus.working.statusDot == AvatarStatusDot(tone: .accent, isFilled: true))
        #expect(AgentStatus.done.statusDot == AvatarStatusDot(tone: .neutral, isFilled: true), "未讀的回覆是 done:實心")
        #expect(AgentStatus.idle.statusDot == AvatarStatusDot(tone: .neutral, isFilled: false), "已讀是 idle:空心")
        #expect(AgentStatus.unknown.statusDot == AvatarStatusDot(tone: .neutral, isFilled: false))
        #expect(ChatRowContent(tab: Self.tab(status: .blocked)).statusDot == AgentStatus.blocked.statusDot)
    }

    @Test("行數:一般字級每行一行,輔助使用字級不截斷")
    func lineLimits() {
        #expect(ChatRowContent.lineLimit(accessibilitySize: false) == 1)
        #expect(ChatRowContent.lineLimit(accessibilitySize: true) == nil)
    }
}
