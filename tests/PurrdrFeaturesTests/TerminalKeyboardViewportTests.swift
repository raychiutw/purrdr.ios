import PurrdrAgentFeatures
import Testing

/// 鍵盤升降不改終端機的欄列數(#357):容器因鍵盤變矮時,終端機視圖維持原高度、只上移到游標可見。
@Suite("鍵盤升降不觸發 resize")
struct TerminalKeyboardViewportTests {
    typealias Size = TerminalKeyboardViewport.Size
    let portrait = Size(width: 400, height: 600)
    let withKeyboard = Size(width: 400, height: 300)

    @Test("沒有鍵盤:終端機高度就是容器高度")
    func followsContainerWithoutKeyboard() {
        var viewport = TerminalKeyboardViewport()
        #expect(viewport.terminalHeight(container: portrait, keyboardVisible: false) == 600)
        #expect(viewport.terminalHeight(container: Size(width: 400, height: 500), keyboardVisible: false) == 500)
    }

    @Test("鍵盤升起使容器變矮:終端機維持原高度(列數不變)")
    func keepsHeightWhenKeyboardShrinksContainer() {
        var viewport = TerminalKeyboardViewport()
        _ = viewport.terminalHeight(container: portrait, keyboardVisible: false)

        #expect(viewport.terminalHeight(container: withKeyboard, keyboardVisible: true) == 600)
        // 鍵盤期間重複排版也一樣
        #expect(viewport.terminalHeight(container: withKeyboard, keyboardVisible: true) == 600)
    }

    @Test("鍵盤收起:回到容器高度,與升起前相同")
    func restoresWhenKeyboardHides() {
        var viewport = TerminalKeyboardViewport()
        _ = viewport.terminalHeight(container: portrait, keyboardVisible: false)
        _ = viewport.terminalHeight(container: withKeyboard, keyboardVisible: true)

        #expect(viewport.terminalHeight(container: portrait, keyboardVisible: false) == 600)
    }

    @Test("鍵盤期間旋轉(寬度變了):重新以新的容器大小為準,旋轉本來就要 resize")
    func rotationWithKeyboardResizes() {
        var viewport = TerminalKeyboardViewport()
        _ = viewport.terminalHeight(container: portrait, keyboardVisible: false)
        _ = viewport.terminalHeight(container: withKeyboard, keyboardVisible: true)

        #expect(viewport.terminalHeight(container: Size(width: 800, height: 150), keyboardVisible: true) == 150)
        // 之後鍵盤收起:容器變高,照容器
        #expect(viewport.terminalHeight(container: Size(width: 800, height: 350), keyboardVisible: false) == 350)
    }

    @Test("實體鍵盤(鍵盤狀態升起但容器沒變矮):照容器高度")
    func hardwareKeyboardDoesNotPin() {
        var viewport = TerminalKeyboardViewport()
        _ = viewport.terminalHeight(container: portrait, keyboardVisible: false)

        #expect(viewport.terminalHeight(container: portrait, keyboardVisible: true) == 600)
    }

    @Test("游標在可見區域內不位移;被鍵盤擋住就上移到剛好看到,最多移到底")
    func caretOffset() {
        // 可見 300、終端機 600
        #expect(TerminalKeyboardViewport.offset(caretBottom: 200, visibleHeight: 300, terminalHeight: 600) == 0)
        #expect(TerminalKeyboardViewport.offset(caretBottom: 450, visibleHeight: 300, terminalHeight: 600) == -150)
        #expect(TerminalKeyboardViewport.offset(caretBottom: 900, visibleHeight: 300, terminalHeight: 600) == -300)
        // 沒有鍵盤(終端機不比可見區域高):不位移
        #expect(TerminalKeyboardViewport.offset(caretBottom: 450, visibleHeight: 600, terminalHeight: 600) == 0)
    }
}
