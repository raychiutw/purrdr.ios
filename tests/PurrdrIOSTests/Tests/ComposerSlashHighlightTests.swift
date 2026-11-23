#if os(iOS)
import Testing
import UIKit
@testable import PurrdrFeatures

/// 輸入框的 slash 指令著色(#469):開頭一律、文中只認已知名稱,組字中不動屬性,接著打的字是一般色。
@Suite(.serialized)
@MainActor
struct ComposerSlashHighlightTests {
    private func makeView(_ text: String, known: Set<String>) -> KeyHandlingTextView {
        let view = KeyHandlingTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.inlineSlashNames = known
        view.text = text
        view.highlightSlashToken()
        return view
    }

    /// 以 `.label` 以外的顏色顯示的子字串。
    private func coloredRanges(in view: KeyHandlingTextView) -> [String] {
        var result: [String] = []
        let storage = view.textStorage
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let color = value as? UIColor, color != .label {
                result.append((storage.string as NSString).substring(with: range))
            }
        }
        return result
    }

    @Test("開頭與文中已知指令都上色，/tmp 與未知名稱不上色")
    func inlineKnownOnly() {
        let view = makeView("/tdd 看 /grill 與 /tmp 與 /nope", known: ["grill"])
        #expect(coloredRanges(in: view) == ["/tdd", "/grill"])
    }

    @Test("已知名稱集合改變後重畫")
    func knownNamesChange() {
        let view = makeView("先 /grill", known: [])
        #expect(coloredRanges(in: view) == [])
        view.inlineSlashNames = ["grill"]
        #expect(coloredRanges(in: view) == ["/grill"])
    }

    @Test("選用後接著打的字是一般色，指令顏色不延續")
    func typingAfterTokenIsPlain() {
        let view = makeView("先 /grill", known: ["grill"])
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.insertText(" ok")
        view.highlightSlashToken()
        #expect(coloredRanges(in: view) == ["/grill"])
        #expect(view.typingAttributes[.foregroundColor] as? UIColor == .label)
    }

    @Test("組字中不動屬性")
    func composingLeavesAttributes() {
        let view = makeView("先 ", known: ["grill"])
        view.selectedRange = NSRange(location: 2, length: 0)
        view.setMarkedText("/grill", selectedRange: NSRange(location: 6, length: 0))
        view.highlightSlashToken()
        #expect(coloredRanges(in: view) == [], "組字中改屬性會打斷輸入法")
        view.unmarkText()
        view.highlightSlashToken()
        #expect(coloredRanges(in: view) == ["/grill"])
    }
}
#endif
