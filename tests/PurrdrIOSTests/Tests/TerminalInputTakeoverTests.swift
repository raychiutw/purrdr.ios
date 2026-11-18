#if os(iOS)
import Foundation
import PurrdrCore
import SwiftTerm
import Testing
import UIKit
@testable import PurrdrFeatures

/// 終端機接管鍵盤輸入(#136):以真正的終端機畫面與輸入元件放進視窗驗證。
@Suite(.serialized)
@MainActor
struct TerminalInputTakeoverTests {
    private final class Recorder {
        var sends: [TerminalInputSend] = []
    }

    private func mount() async throws -> (UIWindow, TerminalScreenContainer, Recorder) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let screen = TerminalScreenContainer(
            terminalView: PurrdrTerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        )
        let recorder = Recorder()
        screen.textInput.onSend = { recorder.sends.append($0) }
        let controller = UIViewController()
        controller.view = screen
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(50))
        #expect(screen.textInput.becomeFirstResponder())
        return (window, screen, recorder)
    }

    @Test("輸入元件是 first responder,終端機畫面不是;點畫面要焦點時交給輸入元件")
    func inputViewOwnsKeyboardFocus() async throws {
        let (window, screen, _) = try await mount()
        defer { window.isHidden = true }

        #expect(screen.textInput.isFirstResponder)
        #expect(!screen.terminalView.canBecomeFirstResponder)
        // SwiftTerm 依這個決定點畫面的行為與游標樣式。
        #expect(screen.terminalView.isFirstResponder)

        _ = screen.textInput.resignFirstResponder()
        #expect(!screen.terminalView.isFirstResponder)
        #expect(screen.terminalView.becomeFirstResponder())
        #expect(screen.textInput.isFirstResponder)
    }

    @Test("沒有組字時：英文、刪除、Return 照舊送出")
    func plainTypingIsSent() async throws {
        let (window, screen, recorder) = try await mount()
        defer { window.isHidden = true }

        screen.textInput.insertText("l")
        screen.textInput.deleteBackward()
        screen.textInput.insertText("\n")

        #expect(recorder.sends == [.bytes(Data("l".utf8)), .bytes(Data([0x7F])), .bytes(Data("\r".utf8))])
    }

    @Test("組字中不送，選字確認後只送確認的文字")
    func compositionSendsOnlyCommittedText() async throws {
        let (window, screen, recorder) = try await mount()
        defer { window.isHidden = true }

        screen.textInput.setMarkedText("ㄋㄧˇ", selectedRange: NSRange(location: 3, length: 0))
        screen.textInput.deleteBackward()
        #expect(screen.textInput.markedTextRange != nil)
        #expect(recorder.sends.isEmpty)

        screen.textInput.insertText("你")
        #expect(screen.textInput.markedTextRange == nil)
        #expect(recorder.sends == [.bytes(Data("你".utf8))])
    }

    @Test("組字中切換焦點：組字文字不送，系統隨後的結束組字也不送")
    func resigningFocusDropsComposition() async throws {
        let (window, screen, recorder) = try await mount()
        defer { window.isHidden = true }

        screen.textInput.setMarkedText("ㄋㄧ", selectedRange: NSRange(location: 2, length: 0))
        _ = screen.textInput.resignFirstResponder()
        screen.textInput.unmarkText()

        #expect(screen.textInput.markedTextRange == nil)
        #expect(recorder.sends.isEmpty)
    }

    @Test("組字中換字型、點畫面：組字留著、什麼都不送")
    func fontChangeAndTapKeepComposition() async throws {
        let (window, screen, recorder) = try await mount()
        defer { window.isHidden = true }

        screen.textInput.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        screen.terminalView.font = UIFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        screen.cursorMayHaveMoved()
        // SwiftTerm 點畫面時在已聚焦的狀態下只處理連結與選取，不會再要焦點。
        _ = screen.terminalView.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(50))

        #expect(screen.textInput.isFirstResponder)
        #expect(screen.textInput.composition.markedText == "ni")
        #expect(recorder.sends.isEmpty)
    }

    @Test("輸入元件跟著遠端游標格子")
    func inputViewSitsOnCursorCell() async throws {
        let (window, screen, _) = try await mount()
        defer { window.isHidden = true }

        screen.terminalView.feed(text: "hello")
        try await Task.sleep(for: .milliseconds(100))
        // 正式畫面由 SwiftTerm 的 rangeChanged(notifyUpdateChanges)呼叫。
        screen.terminalDisplayDidUpdate()

        let caret = screen.terminalView.convert(screen.terminalView.caretFrame, to: screen)
        #expect(caret.minX > 0)
        #expect(screen.textInput.frame == caret)
    }
}
#endif
