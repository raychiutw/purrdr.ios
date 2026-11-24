import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import Testing

@MainActor
@Suite("窄視窗與寬視窗切換時的聊天選取")
struct LayoutSwitchNavigationTests {
    @Test("選取的聊天與推入的終端機屬於導覽狀態,不依賴排版:兩種排版共用同一份")
    func selectionIsLayoutIndependent() {
        let model = TopNavigationModel()
        let route = ChatRoute(host: .demo, paneID: "w1:p1")
        model.selectedChat = route
        model.openedTerminal = route

        // 重設為同一個選取(寬窄切換時兩種排版都綁同一個值)不會收起終端機。
        model.selectedChat = route

        #expect(model.selectedChat == route)
        #expect(model.openedTerminal == route)
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
