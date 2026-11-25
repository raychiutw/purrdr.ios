#if os(iOS)
import PurrdrAgentFeatures
import SwiftUI
import Testing
import UIKit
@testable import PurrdrFeatures

/// 輸入框量到的行數交給形態規則(#512):逐字輸入一行內不展開、到第二行才展開、組字不跳版。
/// 以真正的 `ComposerTextEditor` 放進視窗驗證，量測一律以「收合時的寬度」為準。
@Suite(.serialized)
@MainActor
struct ComposerFormMeasureTests {
    /// 展開時輸入框比收合時寬出的寬度(只用來驗證量測不隨目前形態變)。
    private static let reduction: CGFloat = 100

    @MainActor @Observable
    final class Probe {
        var measure = ComposerLineMeasure.empty
    }

    private struct Host: View {
        let probe: Probe
        let reduction: CGFloat
        let frameWidth: CGFloat
        @State var text = ""
        @State var isFocused = true

        var body: some View {
            ComposerTextEditor(
                text: $text, isFocused: $isFocused,
                options: ComposerEditorOptions(
                    placeholder: "Message", returnSends: false, canSend: true,
                    slashKey: { _ in false }, pasteAction: { .system }, onPasteImages: {}, onSend: {},
                    measureWidthReduction: reduction,
                    onLineMeasure: { probe.measure = $0 }
                )
            )
            .frame(width: frameWidth)
        }
    }

    @Test("逐字輸入：一行放得下時一直是收合，輸入到第二行才展開")
    func typingExpandsOnlyOnSecondLine() async throws {
        let probe = Probe()
        let (window, textView) = try await mount(probe: probe, reduction: 0, width: 250)
        defer { window.isHidden = true }
        var firstExpanded: Int?
        for index in 0..<40 {
            textView.insertText("好")
            await yieldToMainThread(times: 2)
            if form(probe, textView) == .expanded, firstExpanded == nil { firstExpanded = index + 1 }
            if firstExpanded == nil { #expect(probe.measure.lines == 1, "第 \(index + 1) 字還在一行內") }
        }
        let count = try #require(firstExpanded, "輸入 40 字都沒展開")
        // 250pt 寬、扣掉內距與行首尾約 26pt,body 約 17pt:一行約 13 個全形字，之後才換行。
        #expect((10...16).contains(count), "第 \(count) 字才展開")
    }

    @Test("注音組字：組字中的字不讓一行內的輸入框展開")
    func composingDoesNotExpandWithinOneLine() async throws {
        let probe = Probe()
        let (window, textView) = try await mount(probe: probe, reduction: 0, width: 250)
        defer { window.isHidden = true }
        textView.setMarkedText("ㄋㄧˇ", selectedRange: NSRange(location: 3, length: 0))
        await yieldToMainThread(times: 4)

        #expect(textView.markedTextRange != nil, "組字狀態被清掉了")
        #expect(probe.measure.lines == 1)
        #expect(form(probe, textView) == .collapsed)
        // 組字文字很長而超過一行：算進行數，展開。
        let long = String(repeating: "ㄋ", count: 40)
        textView.setMarkedText(long, selectedRange: NSRange(location: 40, length: 0))
        await yieldToMainThread(times: 4)
        #expect(probe.measure.lines > 1)
        #expect(form(probe, textView) == .expanded)
    }

    @Test("量測以收合時的寬度為準：展開時(輸入框較寬)量到同樣的行數")
    func measureIsIndependentOfCurrentForm() async throws {
        let text = String(repeating: "好", count: 18)
        let collapsedProbe = Probe()
        let (collapsedWindow, collapsedView) = try await mount(probe: collapsedProbe, reduction: 0, width: 250)
        defer { collapsedWindow.isHidden = true }
        collapsedView.insertText(text)
        let expandedProbe = Probe()
        let (expandedWindow, expandedView) = try await mount(probe: expandedProbe, reduction: Self.reduction, width: 250 + Self.reduction)
        defer { expandedWindow.isHidden = true }
        expandedView.insertText(text)
        await yieldToMainThread(times: 5)

        #expect(collapsedProbe.measure.lines == 2)
        #expect(expandedProbe.measure.lines == collapsedProbe.measure.lines)
    }

    @Test("刪字退回一行：幾乎填滿的邊界先維持展開，空出一些才收合")
    func deletingBackCollapsesWithHysteresis() async throws {
        let probe = Probe()
        let (window, textView) = try await mount(probe: probe, reduction: 0, width: 250)
        defer { window.isHidden = true }
        textView.insertText(String(repeating: "好", count: 30))
        await yieldToMainThread(times: 4)
        var current = form(probe, textView, current: .collapsed)
        #expect(current == .expanded)
        var sawHeld = false
        while (textView.text as NSString).length > 1 {
            textView.deleteBackward()
            await yieldToMainThread(times: 2)
            current = form(probe, textView, current: current)
            if probe.measure.lines == 1, probe.measure.fill > ComposerForm.collapseFillLimit {
                #expect(current == .expanded, "填滿 \(probe.measure.fill) 時應維持展開")
                sawHeld = true
            }
            if current == .collapsed { break }
        }
        #expect(current == .collapsed)
        #expect(sawHeld, "沒有經過「一行但幾乎填滿」的邊界")
    }

    // MARK: - 輔助

    private func form(_ probe: Probe, _ textView: UITextView, current: ComposerForm = .collapsed) -> ComposerForm {
        ComposerForm.resolve(
            measure: probe.measure, hasNewline: ComposerForm.draftHasNewline(textView.text), hasAttachments: false, current: current)
    }

    private func mount(probe: Probe, reduction: CGFloat, width: CGFloat) async throws -> (UIWindow, KeyHandlingTextView) {
        let windowType: UIView.Type = UIWindow.self
        let window = try #require(windowType.init(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) as? UIWindow)
        window.rootViewController = UIHostingController(rootView: Host(probe: probe, reduction: reduction, frameWidth: width))
        window.makeKeyAndVisible()
        await yieldToMainThread(times: 10)
        let textView = try #require(Self.find(in: window))
        #expect(textView.becomeFirstResponder())
        await yieldToMainThread(times: 10)
        return (window, textView)
    }

    private static func find(in view: UIView) -> KeyHandlingTextView? {
        if let match = view as? KeyHandlingTextView { return match }
        for child in view.subviews {
            if let match = find(in: child) { return match }
        }
        return nil
    }

    private func yieldToMainThread(times: Int) async {
        for _ in 0..<times {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
}
#endif
