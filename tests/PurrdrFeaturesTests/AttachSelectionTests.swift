import PurrdrAgentFeatures
import Testing

@Suite("加入 sheet 的最近照片選取(#386)")
struct AttachSelectionTests {
    @Test("點未選的照片加入選取，依點選順序編號")
    func selectsInOrder() {
        var selection = AttachSelection()
        #expect(selection.toggle("a", limit: 5) == .selected)
        #expect(selection.toggle("b", limit: 5) == .selected)
        #expect(selection.ids == ["a", "b"])
        #expect(selection.count == 2)
        #expect(selection.number(of: "b") == 2)
        #expect(selection.number(of: "z") == nil)
    }

    @Test("再點一次取消選取，後面的編號往前補")
    func deselectRenumbers() {
        var selection = AttachSelection()
        _ = selection.toggle("a", limit: 5)
        _ = selection.toggle("b", limit: 5)
        #expect(selection.toggle("a", limit: 5) == .deselected)
        #expect(selection.number(of: "b") == 1)
    }

    @Test("超過剩餘額度不加入並回報超量")
    func respectsLimit() {
        var selection = AttachSelection()
        _ = selection.toggle("a", limit: 1)
        #expect(selection.toggle("b", limit: 1) == .overLimit)
        #expect(selection.ids == ["a"])
    }

    @Test("額度為 0 時任何照片都不能選")
    func zeroLimit() {
        var selection = AttachSelection()
        #expect(selection.toggle("a", limit: 0) == .overLimit)
        #expect(selection.count == 0)
    }
}
