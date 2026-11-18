#if os(iOS)
import Foundation
import PurrdrCore
import SwiftTerm
import Testing
import UIKit
@testable import PurrdrFeatures

/// 組字浮層與選字窗定位(#140):以真正的終端機畫面與輸入元件放進視窗驗證。
@Suite(.serialized)
@MainActor
struct TerminalCompositionOverlayTests {
    private func mount() async throws -> (UIWindow, TerminalScreenContainer) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let screen = TerminalScreenContainer(
            terminalView: PurrdrTerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        )
        let controller = UIViewController()
        controller.view = screen
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(50))
        #expect(screen.textInput.becomeFirstResponder())
        return (window, screen)
    }

    /// 餵輸出並等 SwiftTerm 更新畫面(正式畫面由 rangeChanged 呼叫 `terminalDisplayDidUpdate`)。
    private func feed(_ text: String, to screen: TerminalScreenContainer) async throws {
        screen.terminalView.feed(text: text)
        try await Task.sleep(for: .milliseconds(100))
        screen.terminalDisplayDidUpdate()
    }

    @Test("組字時浮層出現在游標格子，寬度是組字文字的格數，accessibility 值是組字文字")
    func overlayAppearsOnCursorCellWhileComposing() async throws {
        let (window, screen) = try await mount()
        defer { window.isHidden = true }
        try await feed("$ ", to: screen)
        let cell = screen.textInput.frame
        let overlay = screen.compositionOverlay

        #expect(overlay.isHidden)
        screen.textInput.setMarkedText("ㄋㄧˇ", selectedRange: NSRange(location: 3, length: 0))

        #expect(!overlay.isHidden)
        #expect(overlay.frame.origin == cell.origin)
        #expect(overlay.frame.height == cell.height)
        // ㄋ、ㄧ 各兩格，ˇ 一格。
        #expect(abs(overlay.frame.width - cell.width * 5) < 0.01)
        #expect(overlay.accessibilityIdentifier == "terminal.composition")
        #expect(overlay.accessibilityValue == "ㄋㄧˇ")
    }

    @Test("確認或取消後浮層消失")
    func overlayHidesAfterCommitOrCancel() async throws {
        let (window, screen) = try await mount()
        defer { window.isHidden = true }
        let overlay = screen.compositionOverlay

        screen.textInput.setMarkedText("ㄋㄧˇ", selectedRange: NSRange(location: 3, length: 0))
        screen.textInput.insertText("你")
        #expect(overlay.isHidden)

        screen.textInput.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        _ = screen.textInput.resignFirstResponder()
        #expect(overlay.isHidden)

        _ = screen.textInput.becomeFirstResponder()
        screen.textInput.setMarkedText("ㄏ", selectedRange: NSRange(location: 1, length: 0))
        screen.textInput.deleteBackward()
        #expect(overlay.isHidden)
    }

    @Test("遠端游標移動時浮層跟著移動")
    func overlayFollowsRemoteCursor() async throws {
        let (window, screen) = try await mount()
        defer { window.isHidden = true }
        try await feed("$ ", to: screen)
        screen.textInput.setMarkedText("ㄋㄧ", selectedRange: NSRange(location: 2, length: 0))
        let before = screen.compositionOverlay.frame

        try await feed("\r\noutput\r\n$ ", to: screen)

        let after = screen.compositionOverlay.frame
        #expect(after.minY > before.minY)
        #expect(after.origin == screen.textInput.frame.origin)
        #expect(!screen.compositionOverlay.isHidden)
    }

    @Test("游標在寬字元後面時，格子寬度仍是一格")
    func cellWidthStaysSingleAfterWideCharacter() async throws {
        let (window, screen) = try await mount()
        defer { window.isHidden = true }
        try await feed("a", to: screen)
        let single = screen.textInput.frame

        try await feed("你", to: screen)

        #expect(abs(screen.textInput.frame.width - single.width) < 0.01)
        #expect(abs(screen.textInput.frame.minX - (single.minX + single.width * 2)) < 0.01)
    }

    @Test("firstRect／caretRect:沒有組字時是游標格子，組字中對齊組字段")
    func candidateWindowRectsFollowCursorCell() async throws {
        let (window, screen) = try await mount()
        defer { window.isHidden = true }
        try await feed("$ ", to: screen)
        let input = screen.textInput
        let cell = CGRect(origin: .zero, size: input.frame.size)

        #expect(input.firstRect(for: input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)!) == cell)
        #expect(input.caretRect(for: input.endOfDocument) == CGRect(x: 0, y: 0, width: 2, height: cell.height))

        input.setMarkedText("ㄋㄧ", selectedRange: NSRange(location: 2, length: 0))
        let marked = try #require(input.markedTextRange)
        let firstRect = input.firstRect(for: marked)
        #expect(firstRect.origin == .zero)
        #expect(abs(firstRect.width - cell.width * 4) < 0.01)
        let caret = input.caretRect(for: input.endOfDocument)
        #expect(abs(caret.minX - cell.width * 4) < 0.01)
        #expect(caret.height == cell.height)
    }

    @Test("浮層背景取游標格子的顏色")
    func overlayUsesCursorCellBackground() async throws {
        let (window, screen) = try await mount()
        defer { window.isHidden = true }
        // 背景設成 256 色的 196(純紅)並清到行尾，游標格子就是紅底。
        try await feed("\u{1B}[48;5;196m\u{1B}[K", to: screen)

        screen.textInput.setMarkedText("ㄋ", selectedRange: NSRange(location: 1, length: 0))

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        try #require(screen.compositionOverlay.backgroundColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(red == 1 && green == 0 && blue == 0)
    }
}
#endif
