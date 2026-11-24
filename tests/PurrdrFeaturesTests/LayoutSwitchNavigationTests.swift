import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import Testing

@MainActor
@Suite("窄視窗與寬視窗切換時的聊天選取")
struct LayoutSwitchNavigationTests {
    @Test("切到窄視窗:側欄的 workspace 篩選清掉,選取的聊天與推入的終端機留著")
    func compactKeepsSelectedChat() {
        let model = TopNavigationModel()
        let route = ChatRoute(host: .demo, paneID: "w1:p1")
        model.selectedChat = route
        model.openedTerminal = route
        model.workspaceFilter = "w1"

        model.layoutChanged(isCompact: true)

        #expect(model.workspaceFilter == nil)
        #expect(model.selectedChat == route)
        #expect(model.openedTerminal == route)
    }

    @Test("切到寬視窗:篩選與選取都不動")
    func regularChangesNothing() {
        let model = TopNavigationModel()
        let route = ChatRoute(host: .demo, paneID: "w1:p1")
        model.selectedChat = route
        model.workspaceFilter = "w1"

        model.layoutChanged(isCompact: false)

        #expect(model.workspaceFilter == "w1")
        #expect(model.selectedChat == route)
    }

    @Test("窄視窗返回列表(選取設成 nil)後終端機也收起")
    func popClearsTerminal() {
        let model = TopNavigationModel()
        let route = ChatRoute(host: .demo, paneID: "w1:p1")
        model.selectedChat = route
        model.openedTerminal = route
        model.selectedChat = nil
        #expect(model.openedTerminal == nil)
    }
}
