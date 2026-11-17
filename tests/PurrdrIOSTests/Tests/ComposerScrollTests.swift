#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import PurrdrFeatures

/// 輸入框超過 4 行內捲後，捲動位置一律包含游標(#88 第 4 項)。以真正的 `ComposerTextEditor` 放進視窗驗證。
@Suite(.serialized)
@MainActor
struct ComposerScrollTests {
    /// 跟輸入列一樣放在兩側有按鈕的 HStack 裡:SwiftUI 會以 0 與無限寬度探問理想大小。
    private struct Host: View {
        @State var text = ""
        @State var isFocused = true

        var body: some View {
            HStack(alignment: .bottom, spacing: 8) {
                Color.clear.frame(width: 44, height: 44)
                ComposerTextEditor(
                    text: $text, isFocused: $isFocused, returnSends: false, canSend: true,
                    slashKey: { _ in false }, pasteAction: { .system }, onPasteImages: {}, onSend: {}
                )
                .frame(minHeight: 44)
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal)
            .frame(width: 390)
        }
    }

    /// 超過 4 行的草稿(寬 280pt 約 10 行)。
    private static let longDraft = String(repeating: "這是一段很長的文字用來把輸入框撐到四行以上", count: 6)

    @Test("逐字輸入超過 4 行：捲動位置包含游標")
    func typingBeyondFourLinesKeepsCaretVisible() async throws {
        let (window, textView) = try await mount()
        defer { window.isHidden = true }
        for character in Self.longDraft {
            textView.insertText(String(character))
            await yieldToMainThread(times: 1)
        }
        await settle()

        #expect(textView.isScrollEnabled)
        expectCaretVisible(in: textView)
    }

    @Test("內捲後組字：捲動位置包含組字尾端的游標")
    func composingBeyondFourLinesKeepsCaretVisible() async throws {
        let (window, textView) = try await mount()
        defer { window.isHidden = true }
        for character in Self.longDraft {
            textView.insertText(String(character))
            await yieldToMainThread(times: 1)
        }
        await settle()
        let composing = "再組一段字讓它換到下一行"
        textView.setMarkedText(composing, selectedRange: NSRange(location: (composing as NSString).length, length: 0))
        await settle()

        #expect(textView.markedTextRange != nil, "組字狀態被清掉了")
        expectCaretVisible(in: textView)
    }

    @Test("貼上一大段文字：捲動位置停在貼上的結尾")
    func pastingLongTextKeepsCaretVisible() async throws {
        let (window, textView) = try await mount()
        defer { window.isHidden = true }
        textView.insertText(Self.longDraft)
        await settle()

        #expect(textView.isScrollEnabled)
        expectCaretVisible(in: textView)
    }

    @Test("刪字縮回 4 行以內：關掉內捲並顯示全部文字")
    func deletingBackWithinFourLinesShowsAllText() async throws {
        let (window, textView) = try await mount()
        defer { window.isHidden = true }
        textView.insertText(Self.longDraft)
        await settle()
        while (textView.text as NSString).length > 20 {
            textView.deleteBackward()
            await yieldToMainThread(times: 1)
        }
        await settle()

        #expect(!textView.isScrollEnabled)
        #expect(textView.contentOffset.y <= 0.5, "縮回後仍捲在 \(textView.contentOffset.y)")
        expectCaretVisible(in: textView)
    }

    // MARK: - 輔助

    private func mount() async throws -> (UIWindow, KeyHandlingTextView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Host())
        window.makeKeyAndVisible()
        await settle()
        let textView = try #require(Self.find(in: window))
        #expect(textView.becomeFirstResponder())
        await settle()
        return (window, textView)
    }

    private static func find(in view: UIView) -> KeyHandlingTextView? {
        if let match = view as? KeyHandlingTextView { return match }
        for child in view.subviews {
            if let match = find(in: child) { return match }
        }
        return nil
    }

    /// 游標(組字中是組字尾端)整個落在可見範圍內。
    private func expectCaretVisible(in textView: UITextView, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let caretPosition = textView.selectedTextRange?.end else {
            Issue.record("沒有游標", sourceLocation: sourceLocation)
            return
        }
        let caret = textView.caretRect(for: caretPosition)
        let visibleTop = textView.contentOffset.y
        let visibleBottom = visibleTop + textView.bounds.height
        #expect(caret.minY >= visibleTop - 0.5 && caret.maxY <= visibleBottom + 0.5,
                "游標 \(caret.minY)…\(caret.maxY) 不在可見範圍 \(visibleTop)…\(visibleBottom)(內容高 \(textView.contentSize.height))",
                sourceLocation: sourceLocation)
    }

    /// 讓 SwiftUI 跑完 binding 更新、`updateUIView`、`sizeThatFits` 與排到主執行緒的工作。
    /// 必須讓出主執行緒(`Task.sleep`);`RunLoop.run` 等不到 `DispatchQueue.main.async`。
    private func settle() async {
        await yieldToMainThread(times: 10)
    }

    private func yieldToMainThread(times: Int) async {
        for _ in 0..<times {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
}
#endif
