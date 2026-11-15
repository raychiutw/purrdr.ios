import PurrdrCore
import SwiftUI

/// 硬體鍵盤「Return 送出」設定的 key(`@AppStorage`)。預設開(行為規格 F6.3)。
public enum ComposerSettings {
    public static let returnSendsKey = "composer.returnSends"
}

/// 輸入列(行為規格 F6.1;HIG 20.6)。
///
/// - 功能層：放在 `safeAreaBar`,玻璃材質只用 regular 並包在 `GlassEffectContainer`。
/// - 多行，長到 4 行後內捲;**軟體鍵盤的 Return 永遠是換行**,硬體鍵盤規則見 `ComposerKeys`。
/// - 送出鈕是唯一 tinted 主要動作(44pt),送出中顯示轉圈。聚焦時有「收起鍵盤」(保留草稿、不送出)。
/// - agent 在工作時有停止鈕(非 tinted);長按確認後強制結束。
struct ComposerBar: View {
    @Bindable var model: ConversationModel
    @AppStorage(ComposerSettings.returnSendsKey) private var returnSends = true
    @State private var isFocused = false
    @State private var confirmsForceQuit = false

    var body: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                SendNoticeView(notice: notice) { model.dismissNotice() }
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    if model.canStop || model.isStopping {
                        stopButton
                    }
                    editor
                    if isFocused {
                        hideKeyboardButton
                    }
                    sendButton
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .confirmationDialog("Force Quit the Agent?", isPresented: $confirmsForceQuit, titleVisibility: .visible) {
            Button("Force Quit", role: .destructive) {
                Task { await model.forceQuit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Control-C may end the agent process and this session. The conversation stays on the host, but the agent stops. Stop only interrupts the current turn.")
        }
    }

    // MARK: - 輸入框

    private var editor: some View {
        ComposerTextEditor(text: $model.draft, isFocused: $isFocused, returnSends: returnSends, canSend: model.canSend) {
            send()
        }
        .overlay(alignment: .topLeading) {
            if model.draft.isEmpty {
                Text("Message")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            // 聚焦時邊框 tint(F6.1)。
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 按鈕

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if model.isSending {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!model.canSend)
        .accessibilityLabel(model.isSending ? Text("Sending") : Text("Send"))
        .accessibilityIdentifier("composer.send")
    }

    private var hideKeyboardButton: some View {
        Button {
            isFocused = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text("Hide Keyboard"))
        .accessibilityIdentifier("composer.hideKeyboard")
    }

    private var stopButton: some View {
        Button {
            Task { await model.stop() }
        } label: {
            Group {
                if model.isStopping {
                    ProgressView()
                } else {
                    Image(systemName: "stop.fill")
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(model.isStopping)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in confirmsForceQuit = true })
        .accessibilityLabel(Text("Stop"))
        .accessibilityHint(Text("Interrupts the agent’s current turn. Press and hold to force quit."))
        .accessibilityAction(named: Text("Force Quit")) { confirmsForceQuit = true }
        .accessibilityIdentifier("composer.stop")
    }

    private func send() {
        Task { await model.send() }
    }
}

// MARK: - 提示

/// 送出與中斷的提示：留在畫面上直到使用者關閉、下一次送出或對話紀錄確認(不自動消失,R-P11)。
struct SendNoticeView: View {
    let notice: SendNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(notice.text, systemImage: notice.symbol)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Dismiss"))
            .accessibilityIdentifier("composer.notice.dismiss")
        }
        .padding(.leading, 12)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.notice")
    }
}

extension SendNotice {
    var text: String {
        switch self {
        case .needsAnswer: String(localized: "The agent is waiting for an answer. Answer it first, then send.")
        case .agentGone: String(localized: "This pane no longer has an agent. Your message wasn’t sent.")
        case .superseded: String(localized: "This pane is running a different chat now. Your message wasn’t sent.")
        case .offline: String(localized: "Can’t reach the host. Your message wasn’t sent.")
        case .rejected(let message): String(localized: "Couldn’t send: \(message)")
        case .noResponse: String(localized: "The agent didn’t pick up the message. It may be stuck on a prompt; check the terminal, then try again.")
        case .unconfirmed(.connectionLost): String(localized: "The connection dropped while sending. The message may have arrived; check the chat before sending again.")
        case .unconfirmed(.mayBeInTerminal): String(localized: "Couldn’t confirm delivery. The message may be stuck in the terminal.")
        case .unconfirmed(.codexNoReceipt): String(localized: "Sent to Codex, but its transcript hasn’t confirmed it yet. Check the host before trying again.")
        case .stillWorking: String(localized: "The agent is still working. Tap Stop again, or press and hold to force quit.")
        case .interruptFailed: String(localized: "Couldn’t send the interrupt to the host.")
        }
    }

    var symbol: String {
        switch self {
        case .needsAnswer: "exclamationmark.circle"
        case .agentGone, .superseded: "xmark.bubble"
        case .offline: "wifi.slash"
        case .rejected, .noResponse, .interruptFailed: "exclamationmark.triangle"
        case .unconfirmed: "questionmark.circle"
        case .stillWorking: "ellipsis.circle"
        }
    }
}

// MARK: - 回音

/// 還沒被對話紀錄確認的使用者訊息。外觀同使用者泡泡;失敗時下方有說明與「重試」(44pt,F6.5)。
struct EchoBubbleView: View {
    let echo: PromptEcho
    let retry: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 4) {
                Text(echo.text)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel(Text("Your message. \(echo.text)"))
                status
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.echo")
    }

    @ViewBuilder
    private var status: some View {
        switch echo.state {
        case .sending:
            Text("Sending…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .sent:
            Text("Sent")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let failure):
            HStack(spacing: 4) {
                Label(failure.text, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry", action: retry)
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("conversation.echo.retry")
            }
        }
    }
}

extension EchoFailure {
    var text: String {
        switch self {
        case .noResponse: String(localized: "Not Delivered")
        case .unconfirmed: String(localized: "Not Confirmed")
        }
    }
}

// MARK: - 文字輸入

#if canImport(UIKit)
import UIKit

/// 多行輸入框(UITextView):需要看到輸入法組字狀態(`markedTextRange`)與硬體鍵盤的 Return,SwiftUI 的 TextField 拿不到。
struct ComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var returnSends: Bool
    var canSend: Bool
    var onSend: () -> Void

    /// 長到 4 行後內捲(F6.1)。
    static let maxLines: CGFloat = 4
    static let insets = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> KeyHandlingTextView {
        let view = KeyHandlingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = Self.insets
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "composer.text"
        view.accessibilityLabel = String(localized: "Message")
        view.text = text
        return view
    }

    func updateUIView(_ view: KeyHandlingTextView, context: Context) {
        context.coordinator.parent = self
        view.returnAction = { modifiers, isComposing in
            ComposerKeys.actionForReturn(modifiers: modifiers, returnSends: returnSends, canSend: canSend, isComposing: isComposing)
        }
        view.onSend = onSend
        if view.text != text {
            // 程式改寫草稿(送出、被拒恢復)時，游標保持與結尾的距離(F6.3)。
            let fromEnd = (view.text as NSString).length - view.selectedRange.location - view.selectedRange.length
            view.text = text
            let location = max(0, (text as NSString).length - max(0, fromEnd))
            view.selectedRange = NSRange(location: location, length: 0)
        }
        if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyHandlingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = (uiView.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        let maxHeight = ceil(lineHeight * Self.maxLines + Self.insets.top + Self.insets.bottom)
        let scrolls = fitting > maxHeight
        if uiView.isScrollEnabled != scrolls {
            DispatchQueue.main.async { uiView.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: min(fitting, maxHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextEditor

        init(parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        // 收起鍵盤是在 updateUIView 裡 resign,這時 binding 已經是 false:只在值不同時才寫，避免在畫面更新中改狀態。
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

/// 攔截硬體鍵盤 Return 的 UITextView。軟體鍵盤不經過 `pressesBegan`,所以 Return 永遠換行。
final class KeyHandlingTextView: UITextView {
    var returnAction: ((ReturnModifiers, Bool) -> ComposerKeyAction)?
    var onSend: (() -> Void)?
    private var handled = Set<UIPress>()

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var passThrough = Set<UIPress>()
        for press in presses {
            guard let key = press.key, key.keyCode == .keyboardReturnOrEnter, let returnAction else {
                passThrough.insert(press)
                continue
            }
            var modifiers = ReturnModifiers()
            if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
            switch returnAction(modifiers, markedTextRange != nil) {
            case .system:
                passThrough.insert(press)
            case .send:
                handled.insert(press)
                onSend?()
            case .insertNewline:
                handled.insert(press)
                insertText("\n")
            case .ignore:
                handled.insert(press)
            }
        }
        if !passThrough.isEmpty { super.pressesBegan(passThrough, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handled)
        handled.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handled)
        handled.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}
#else
/// macOS(`swift test` 編譯用)的替代：多行 TextField。
struct ComposerTextEditor: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var returnSends: Bool
    var canSend: Bool
    var onSend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .focused($focused)
            .onChange(of: focused) { isFocused = focused }
            .onChange(of: isFocused) { focused = isFocused }
            .accessibilityIdentifier("composer.text")
    }
}
#endif
