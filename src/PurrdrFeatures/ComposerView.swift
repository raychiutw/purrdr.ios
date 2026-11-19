import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 硬體鍵盤「Return 送出」設定的 key(`@AppStorage`)。預設開(行為規格 F6.3)。
public enum ComposerSettings {
    public static let returnSendsKey = "composer.returnSends"
}

/// 對話目前的可見高度(#196):`ConversationView` 從捲動量測寫入，只有輸入列讀。
@MainActor @Observable
final class ConversationVisibleHeight {
    /// 沒有訊息列表(載入中、空白)時是 `nil`。
    private(set) var value: Double?
    /// 輸入列上方元素的顯示方式改了幾次：對話跟隨中時據此捲回最新一列(收起鍵盤時註記卡片一下子長回來，
    /// 又碰上大量輸出重建列表時，LazyVStack 會停在內容之外、一列都不畫)。
    private(set) var arrangementRevision = 0

    func arrangementChanged() { arrangementRevision += 1 }

    /// 值沒變就不寫，不讓讀它的輸入列重畫。
    func update(_ height: Double?) {
        if value != height { value = height }
    }
}

/// 輸入列(行為規格 F6.1;HIG 20.6)。
///
/// - 功能層：放在 `safeAreaBar`,玻璃材質只用 regular 並包在 `GlassEffectContainer`。
/// - 上下版面(#187):一張玻璃卡片，整寬輸入框在上，按鈕列(加入圖片｜收起鍵盤、送出)在下。
/// - 多行，空白時一行高、有內容時至少兩行高，依可用空間長高(`ComposerSizing`:8 行且不超過鍵盤上方可用高度的 40%)後內捲;**軟體鍵盤的 Return 永遠是換行**,硬體鍵盤規則見 `ComposerKeys`。
/// - 送出鈕是唯一 tinted 主要動作(44pt),送出中顯示轉圈。聚焦時有「收起鍵盤」(保留草稿、不送出)。
/// - 停止與強制結束在標題列(#44,`ConversationView`)。
/// - 自訂回答(#120):點問題卡的「Type something.」後輸入框取得焦點、提示改成打回答，上方有可取消的說明;
///   這時不能附圖。打過字之後清空輸入框也會取消(#127,`ConversationModel`)。
/// - 內容超過 2 行或聚焦時有「展開」鈕(`ComposerExpansion`,#142),打開 `ExpandedComposer`。
/// - 鍵盤出現時 You should know 註記與建議提示詞依 `ComposerKeyboardLayout` 收成一行或暫時拿掉，對話至少留最小可見高度(#196)。
struct ComposerBar: View {
    @Bindable var model: ConversationModel
    /// 對話目前的可見高度(`ConversationView` 從捲動量測回報)。
    var conversationHeight: ConversationVisibleHeight
    @AppStorage(ComposerSettings.returnSendsKey) private var returnSends = true
    @State private var isFocused = false
    /// 鍵盤上方可用高度(輸入框量到後回報;變了要重新量輸入框高度)。
    @State private var availableHeight: CGFloat?
    /// 輸入框回報的「展開」鈕顯示條件。
    @State private var showsExpandButton = false
    @State private var isExpanded = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 內文一行的高度(最小對話可見高度用)。
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight = 22.0
    /// 鍵盤出現時註記與建議提示詞的顯示方式(#196)。
    @State private var arrangement = ComposerAccessoryArrangement.full
    @State private var noteHeights = ComposerAccessoryHeights(full: nil)
    @State private var suggestionHeights = ComposerAccessoryHeights(full: nil)

    /// 讓位規則的輸入;變了就重新決定顯示方式。
    private struct ArrangementInput: Equatable {
        var keyboardShown: Bool
        var conversationHeight: Double?
        var note: ComposerAccessoryHeights?
        var suggestion: ComposerAccessoryHeights?
        var minimum: Double
    }

    private struct NotesKey: Equatable {
        var active: Bool
        var notes: ObjectIdentifier?
    }

    var body: some View {
        if model.isReadOnly {
            ReadOnlyComposerNotice()
                .padding(.horizontal)
                .padding(.bottom, 8)
        } else {
            composer
        }
    }

    private var composer: some View {
        // 間距與讓位規則估算高度用的是同一個常數。
        VStack(spacing: ComposerKeyboardLayout.spacing) {
            if model.slash.isVisible {
                SlashMenuView(menu: model.slash)
            }
            if model.isShellMode {
                ShellModeHint()
            }
            if let notice = model.notice {
                SendNoticeView(notice: notice) { model.dismissNotice() }
            }
            if let option = model.typedAnswer {
                TypedAnswerBanner(question: model.prompt?.question, option: option) { model.cancelTypedAnswer() }
            }
            // 「You should know」:只顯示這個輸入框要送往的 session 的那則(#23)。
            // slash 選單開著時先收起：鍵盤、選單、註記同時在時，AX 字級下註記卡片被擠到截字(#35)。
            if let note = model.note, let notes = model.youShouldKnow, !model.slash.isVisible {
                switch arrangement.note {
                case .full:
                    YouShouldKnowNoteView(note: note, model: notes, conversation: model)
                        .onGeometryChange(for: Double.self) { $0.size.height } action: { noteHeights.full = $0 }
                case .compact:
                    // 點了收起鍵盤、完整卡片(含動作)回來。
                    YouShouldKnowCompactNoteView(note: note) { expandAccessories() }
                        .onGeometryChange(for: Double.self) { $0.size.height } action: { noteHeights.compact = $0 }
                case .hidden:
                    // 只在鍵盤出現時：失焦時換回一行(`ComposerKeyboardLayout`)。
                    EmptyView()
                }
            }
            if !model.attachments.isEmpty && model.typedAnswer == nil {
                AttachmentStrip(model: model)
            }
            // Claude Code 的建議提示詞(#123):只在輸入框空白時有，點了填入並聚焦，不送出。
            if let suggestion = model.suggestion, arrangement.suggestion != .hidden {
                let isCompact = arrangement.suggestion == .compact
                PromptSuggestionView(suggestion: suggestion, isCompact: isCompact) { acceptSuggestion() }
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                        if isCompact { suggestionHeights.compact = height } else { suggestionHeights.full = height }
                    }
            }
            // 上下版面(#187):一張玻璃卡片，整寬輸入框在上、按鈕列在下;卡片內的按鈕不再疊玻璃。
            GlassEffectContainer {
                VStack(spacing: 0) {
                    editor
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    buttonRow
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius))
                .overlay {
                    // 聚焦時中性邊框(F6.1);主色只留給送出鈕(HIG CO-4,#236)。
                    RoundedRectangle(cornerRadius: Self.cardCornerRadius)
                        .strokeBorder(isFocused ? AnyShapeStyle(.separator) : AnyShapeStyle(.clear), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        // 點了「Type something.」:輸入框取得焦點(#120)。離開聊天就取消。
        .onChange(of: model.typedAnswer) { _, option in
            if option != nil { isFocused = true }
        }
        .onDisappear { model.cancelTypedAnswer() }
        .onChange(of: arrangementInput, initial: true) { _, input in
            let next = ComposerKeyboardLayout.arrangement(
                keyboardShown: input.keyboardShown, conversationHeight: input.conversationHeight, current: arrangement,
                note: input.note, suggestion: input.suggestion, minimumConversationHeight: input.minimum)
            guard next != arrangement else { return }
            arrangement = next
            conversationHeight.arrangementChanged()
        }
        // 換了註記、建議或字級：量過的高度不再準。
        .onChange(of: model.note?.line) { noteHeights = ComposerAccessoryHeights(full: nil) }
        .onChange(of: model.suggestion) { suggestionHeights = ComposerAccessoryHeights(full: nil) }
        .onChange(of: dynamicTypeSize) {
            noteHeights = ComposerAccessoryHeights(full: nil)
            suggestionHeights = ComposerAccessoryHeights(full: nil)
        }
        // 對話可見且在前景時讀註記;與列表共用同一個讀取迴圈(列表被蓋住時它不再看)。
        .task(id: NotesKey(active: scenePhase == .active, notes: model.youShouldKnow.map(ObjectIdentifier.init))) {
            guard scenePhase == .active else { return }
            await model.youShouldKnow?.liveUpdates.attach()
        }
        // 用 sheet 而非 fullScreenCover:後者會讓底下的對話 onDisappear(取消自訂回答、停掉輪詢)。
        .sheet(isPresented: $isExpanded) {
            ExpandedComposer(model: model, placeholder: placeholder, returnSends: returnSends) {
                isExpanded = false
            }
        }
    }

    /// 點一行的註記：收起鍵盤，註記與建議提示詞完整顯示(鍵盤收起時規則不會自己換回完整卡片)。
    private func expandAccessories() {
        isFocused = false
        guard arrangement != .full else { return }
        arrangement = .full
        conversationHeight.arrangementChanged()
    }

    private var arrangementInput: ArrangementInput {
        let showsNote = model.note != nil && model.youShouldKnow != nil && !model.slash.isVisible
        return ArrangementInput(
            // 聚焦時才有鍵盤;實體鍵盤只有快捷列，對話夠高，規則自然完整顯示。
            // 只在聚焦時讀對話高度：沒聚焦時不必讓位，也不讓輸入列隨每次捲動量測重畫(載入、大量輸出時
            // 列表會被捲到內容之外，`ConversationUITests` 的載入與大量輸出案例)。
            keyboardShown: isFocused, conversationHeight: isFocused ? conversationHeight.value : nil,
            note: showsNote ? noteHeights : nil, suggestion: model.suggestion == nil ? nil : suggestionHeights,
            minimum: ComposerKeyboardLayout.minimumConversationHeight(bodyLineHeight: bodyLineHeight))
    }

    // MARK: - 輸入框

    private var editor: some View {
        ComposerTextEditor(
            text: $model.draft, isFocused: $isFocused, availableHeight: $availableHeight, showsExpandButton: $showsExpandButton,
            options: ComposerEditorOptions(
                placeholder: placeholder, returnSends: returnSends, canSend: model.canSend,
                slashKey: { model.slash.handle($0) },
                tabKey: acceptSuggestion,
                onComposingChange: { model.isComposingDraft = $0 },
                pasteAction: { [model] in ComposerPasteHandler.action(for: model) },
                onPasteImages: { [model] in ComposerPasteHandler.attachPasteboardImages(to: model) },
                onSend: send
            )
        )
        .overlay(alignment: .topLeading) {
            if let hint = model.slashArgumentHint {
                // 點選需要參數的 slash 指令後，游標後淡淡顯示要填什麼(#45)。草稿本身透明，只為了把提示排在它後面。
                Text(Self.ghost(draft: model.draft, hint: hint))
                    .lineLimit(1)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text("Argument: \(hint)"))
                    .accessibilityIdentifier("composer.argumentHint")
            }
            if model.draft.isEmpty {
                Text(verbatim: placeholder)
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .overlay(alignment: .topTrailing) {
            if showsExpandButton {
                expandButton
            }
        }
    }

    private var expandButton: some View {
        Button {
            // 打開前就交出焦點：不然 sheet 收回時 UIKit 把焦點還給輸入列、叫出鍵盤。
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            isFocused = false
            isExpanded = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondaryText)
        .accessibilityLabel(Text("Expand"))
        .accessibilityIdentifier("composer.expand")
    }

    /// 輸入框的提示(也是朗讀標籤)。
    private var placeholder: String {
        model.typedAnswer == nil ? String(localized: "Message") : String(localized: "Type your answer")
    }

    private static func ghost(draft: String, hint: String) -> AttributedString {
        var typed = AttributedString(draft)
        typed.foregroundColor = .clear
        var placeholder = AttributedString(hint)
        placeholder.foregroundColor = .secondaryText
        placeholder.font = .body.monospaced()
        return typed + placeholder
    }

    // MARK: - 按鈕

    private static let cardCornerRadius: CGFloat = 24

    /// 卡片下半的按鈕列：左加入圖片，右收起鍵盤(聚焦時)與送出。
    private var buttonRow: some View {
        HStack(spacing: 8) {
            if model.canAttachImages && model.typedAnswer == nil {
                AddImageButton(model: model, isInCard: true)
            }
            Spacer(minLength: 0)
            if isFocused {
                hideKeyboardButton
            }
            ComposerSendButton(model: model, identifier: "composer.send", isInCard: true, action: send)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private var hideKeyboardButton: some View {
        Button {
            isFocused = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .frame(width: 30, height: 30)
        }
        .composerSecondaryButtonStyle(isInCard: true)
        .buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text("Hide Keyboard"))
        .accessibilityIdentifier("composer.hideKeyboard")
    }

    private func send() {
        Task { await model.send() }
    }

    /// 接受建議(點建議列，或輸入框空白時按硬體鍵盤 Tab):填入輸入框並叫出鍵盤，游標在結尾。沒有建議回 `false`。
    @discardableResult
    private func acceptSuggestion() -> Bool {
        guard model.acceptSuggestion() else { return false }
        isFocused = true
        return true
    }
}

/// 送出鈕：唯一 tinted 主要動作(44pt),送出中顯示轉圈。輸入列與展開畫面共用。
struct ComposerSendButton: View {
    let model: ConversationModel
    let identifier: String
    /// 放在輸入列的玻璃卡片裡(#187):不再疊玻璃。
    var isInCard = false
    let action: () -> Void

    var body: some View {
        styled(Button(action: action) {
            Group {
                if model.isSending {
                    ProgressView()
                        .tint(OnProminentFillStyle())
                } else {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                }
            }
            .frame(width: 30, height: 30)
        })
        .buttonBorderShape(.circle)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!model.canSend)
        .accessibilityLabel(model.isSending ? Text("Sending") : Text("Send"))
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func styled(_ button: some View) -> some View {
        if isInCard {
            button.filledProminentButtonStyle()
        } else {
            button.filledGlassProminentButtonStyle()
        }
    }
}

extension View {
    /// 輸入列次要圓鈕(加入圖片、收起鍵盤):卡片內用中性色的 bordered(紅色只給送出),卡片外用玻璃(#187)。
    @ViewBuilder
    func composerSecondaryButtonStyle(isInCard: Bool) -> some View {
        if isInCard {
            buttonStyle(.bordered).tint(.primary)
        } else {
            buttonStyle(.glass)
        }
    }
}

// MARK: - 提示

/// Shell 模式提示(F6.4):Claude 聊天的草稿以 `!` 開頭時，說明這會在 agent 的 shell 執行，不會送給 Claude。
struct ShellModeHint: View {
    var body: some View {
        Label("This runs in the agent’s shell and won’t be sent to Claude.", systemImage: "terminal")
            .font(.footnote)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("composer.shellHint")
    }
}

/// 唯讀裝置(#60):輸入列換成說明，沒有輸入框與送出鈕。
struct ReadOnlyComposerNotice: View {
    var body: some View {
        Label("This device is paired read-only, so it can’t send anything to this host.", systemImage: "lock")
            .font(.footnote)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(.bar, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("composer.readOnly")
    }
}

/// 自訂回答的說明(#120):在回答哪一題，送出就是回答;✕ 取消自訂回答、回到一般輸入(什麼都還沒送出)。整個 Label 用 `secondaryText`(DESIGN.md)。
struct TypedAnswerBanner: View {
    let question: String?
    let option: PromptOption
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your answer will be sent to the agent.")
                    if let question {
                        Text(verbatim: question)
                            .lineLimit(2)
                    }
                }
            } icon: {
                Image(systemName: "keyboard")
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondaryText)
            .accessibilityLabel(Text("Cancel Custom Answer"))
            .accessibilityIdentifier("composer.typedAnswer.cancel")
        }
        .padding(.leading, 12)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.typedAnswer")
    }
}

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
            .foregroundStyle(.secondaryText)
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
        case .panelKeysFailed: String(localized: "Couldn’t send the keys to the host. Check the panel in the terminal.")
        case .interruptRefusedNeedsAnswer: String(localized: "The agent is waiting for an answer, so nothing was interrupted. Answer it instead.")
        case .readOnlyDevice: String(localized: "This device is paired read-only, so it can’t send anything to this host.")
        case .imageLimit: String(localized: "You can attach up to 4 images to a message.")
        case .imageUnreadable: String(localized: "Couldn’t read that image.")
        case .imageTooLarge: String(localized: "This image is over 20 MB.")
        case .uploadFailed: String(localized: "Couldn’t upload the image to the host. Your message wasn’t sent; try again.")
        }
    }

    var symbol: String {
        switch self {
        case .needsAnswer, .interruptRefusedNeedsAnswer: "exclamationmark.circle"
        case .agentGone, .superseded: "xmark.bubble"
        case .readOnlyDevice: "lock"
        case .offline: "wifi.slash"
        case .rejected, .noResponse, .interruptFailed, .uploadFailed, .panelKeysFailed: "exclamationmark.triangle"
        case .imageLimit, .imageUnreadable, .imageTooLarge: "photo"
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
    @Environment(\.bubbleImages) private var context

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 4) {
                if !echo.imageFiles.isEmpty {
                    BubbleImagesView(images: echo.imageFiles.map { context.localImage($0) })
                }
                if !echo.text.isEmpty {
                    Text(echo.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .hostFill(in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel(Text("Your message. \(echo.text)"))
                }
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
                .foregroundStyle(.secondaryText)
        case .sent:
            Text("Sent")
                .font(.caption)
                .foregroundStyle(.secondaryText)
        case .failed(let failure):
            HStack(spacing: 4) {
                Label(failure.text, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.errorText)
                Button(action: retry) { HitTarget("Retry") }
                    .font(.caption.weight(.semibold))
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

/// 輸入框的設定與回呼(`ComposerTextEditor` 的 UIKit 版與 macOS 替代版共用)。
struct ComposerEditorOptions {
    /// 展開畫面(#142):填滿給它的空間、一律可捲動，不套用長高規則。
    var isExpanded = false
    var identifier = "composer.text"
    /// 輸入框的提示，也當朗讀標籤。
    var placeholder: String
    var returnSends: Bool
    var canSend: Bool
    /// slash 選單顯示時攔截硬體鍵盤的上下、Return、Tab、Esc(回傳 true 表示已處理)。
    var slashKey: (SlashMenuModel.Key) -> Bool
    /// slash 選單沒處理的硬體鍵盤 Tab(接受建議提示詞，#123;回傳 true 表示已處理，否則交給系統)。
    var tabKey: () -> Bool = { false }
    /// 組字狀態(有 marked text)改變時呼叫(#138)。
    var onComposingChange: (Bool) -> Void = { _ in }
    /// 貼上(Command-V 或編輯選單)時要當圖片附件還是交給系統。
    var pasteAction: () -> ComposerPaste.Action
    var onPasteImages: () -> Void
    var onSend: () -> Void
}

#if canImport(UIKit)
import UIKit

/// 多行輸入框(UITextView):需要看到輸入法組字狀態(`markedTextRange`)與硬體鍵盤的 Return,SwiftUI 的 TextField 拿不到。
struct ComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// 鍵盤上方可用高度，由輸入框回報;只用來讓 SwiftUI 在它變了時重新量高度。
    var availableHeight: Binding<CGFloat?> = .constant(nil)
    /// 「展開」鈕要不要顯示，由輸入框回報(#142);顯示時右側留位置給它。
    var showsExpandButton: Binding<Bool> = .constant(false)
    var options: ComposerEditorOptions

    static let insets = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)
    /// 顯示「展開」鈕時右側內距(鈕疊在輸入框右上角)。
    static let expandButtonInset: CGFloat = 40

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> KeyHandlingTextView {
        let view = KeyHandlingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.fillsAvailableSpace = options.isExpanded
        view.focusesWhenAttached = options.isExpanded
        view.isScrollEnabled = options.isExpanded
        view.textContainerInset = Self.insets
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = options.identifier
        view.accessibilityLabel = options.placeholder
        view.text = text
        // 可能在排版中回報：等這次更新結束再寫狀態。
        let availableHeight = availableHeight
        view.onAvailableHeightChange = { height in
            DispatchQueue.main.async { availableHeight.wrappedValue = height }
        }
        let showsExpandButton = showsExpandButton
        view.onShowsExpandChange = { shows in
            DispatchQueue.main.async { showsExpandButton.wrappedValue = shows }
        }
        return view
    }

    func updateUIView(_ view: KeyHandlingTextView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityLabel = options.placeholder
        view.returnAction = { modifiers, isComposing in
            ComposerKeys.actionForReturn(modifiers: modifiers, returnSends: options.returnSends, canSend: options.canSend, isComposing: isComposing)
        }
        view.onSend = options.onSend
        view.slashKey = options.slashKey
        view.tabKey = options.tabKey
        view.pasteAction = options.pasteAction
        view.onPasteImages = options.onPasteImages
        let trailingInset = showsExpandButton.wrappedValue ? Self.expandButtonInset : Self.insets.right
        if !options.isExpanded, view.textContainerInset.right != trailingInset {
            view.textContainerInset.right = trailingInset
            view.contentDidChange()
        }
        // 程式改寫草稿：組字中延後到組字結束，不打斷正在組的字(#138)。
        if view.text != text,
           let applied = context.coordinator.overwrite.request(text, current: view.text, isComposing: view.markedTextRange != nil) {
            view.replaceText(with: applied)
        }
        if isFocused, !view.isFirstResponder, view.window != nil {
            // 程式要求聚焦(點「Type something.」#120、接受建議後叫出鍵盤 #123):等這次畫面更新結束再取得焦點。
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                if coordinator.parent.isFocused, !view.isFirstResponder { view.becomeFirstResponder() }
            }
        }
        if !isFocused, view.isFirstResponder {
            // 不在畫面更新中 resign:resign 時 UIKit 會問 hosting view 的 responder,又觸發同一張 AttributeGraph 的更新，
            // 形成循環，主執行緒卡上數分鐘(#34 的 UI 測試抓到)。等這次更新結束再收起，那時焦點仍是 false 才收。
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                if !coordinator.parent.isFocused, view.isFirstResponder { view.resignFirstResponder() }
            }
        }
    }

    /// 只回答高度。要不要內捲由視圖依實際寬度決定(`KeyHandlingTextView.layoutSubviews`):
    /// SwiftUI 也會以 0 與無限寬度探問理想大小，拿探問的結果切換內捲會把捲動位置歸零(#94)。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyHandlingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        if options.isExpanded { return CGSize(width: width, height: proposal.height ?? 240) }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        var height = uiView.sizing(contentHeight: fitting).height
        // 卡片上方的元素與鍵盤擠掉空間時讓出高度(不壓到按鈕列，#187);框內捲動由 layoutSubviews 依實際高度決定。
        if let proposed = proposal.height, proposed < height {
            height = max(proposed, ComposerSizing.minHeight)
        }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextEditor
        /// 組字中延後的程式覆寫。
        var overwrite = ComposerOverwrite()
        private var reportedComposing = false

        init(parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            syncDraft(from: textView)
            (textView as? KeyHandlingTextView)?.contentDidChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // 取消組字時文字可能沒變，只有選取範圍變。
            if textView.markedTextRange == nil, overwrite.isPending || reportedComposing { syncDraft(from: textView) }
            (textView as? KeyHandlingTextView)?.contentDidChange()
        }

        /// 把輸入框文字寫回草稿。組字開始先標記再寫、結束先寫再取消標記，slash 選單只看到確認的文字。
        private func syncDraft(from textView: UITextView) {
            let isComposing = textView.markedTextRange != nil
            if let resolved = overwrite.inputChanged(textView.text, isComposing: isComposing) {
                (textView as? KeyHandlingTextView)?.replaceText(with: resolved)
                parent.text = resolved
                reportComposing(false)
                return
            }
            // 有延後的覆寫時草稿維持程式要的內容，組字結束再合併。
            guard !overwrite.isPending else { return }
            if isComposing { reportComposing(true) }
            parent.text = textView.text
            if !isComposing { reportComposing(false) }
        }

        private func reportComposing(_ isComposing: Bool) {
            guard reportedComposing != isComposing else { return }
            reportedComposing = isComposing
            parent.options.onComposingChange(isComposing)
        }

        // 收起鍵盤是在 updateUIView 裡 resign,這時 binding 已經是 false:只在值不同時才寫，避免在畫面更新中改狀態。
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
            (textView as? KeyHandlingTextView)?.contentDidChange()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
            (textView as? KeyHandlingTextView)?.contentDidChange()
        }
    }
}

/// 攔截硬體鍵盤 Return 的 UITextView。軟體鍵盤不經過 `pressesBegan`,所以 Return 永遠換行。
final class KeyHandlingTextView: UITextView {
    var returnAction: ((ReturnModifiers, Bool) -> ComposerKeyAction)?
    var onSend: (() -> Void)?
    var slashKey: ((SlashMenuModel.Key) -> Bool)?
    var tabKey: (() -> Bool)?
    private var handled = Set<UIPress>()
    var pasteAction: (() -> ComposerPaste.Action)?
    var onPasteImages: (() -> Void)?
    /// 草稿或游標變了，下次排版要重新判斷內捲並跟上游標。
    private var needsCaretFollow = false
    private var measuredSize = CGSize.zero
    /// 鍵盤的最後位置(螢幕座標);收起時在螢幕外。
    private var keyboardFrameInScreen: CGRect?
    private var observesKeyboard = false
    /// 鍵盤上方可用高度：視窗安全區域內、鍵盤以上;iPad 分割畫面依當下視窗。
    private(set) var availableHeight: CGFloat?
    var onAvailableHeightChange: ((CGFloat?) -> Void)?
    /// 展開畫面：填滿空間、由 UIKit 自己捲動，不套用長高規則與展開鈕。
    var fillsAvailableSpace = false
    /// 放進視窗後取得焦點一次(展開畫面打開時鍵盤不收起)。
    var focusesWhenAttached = false
    var onShowsExpandChange: ((Bool) -> Void)?
    private var reportedShowsExpand: Bool?

    /// 依目前字級與可用高度，內容高 `contentHeight` 時輸入框的高度與是否內捲(#137)。
    func sizing(contentHeight: CGFloat) -> ComposerHeight {
        ComposerSizing.height(metrics(contentHeight: contentHeight), isEmpty: text.isEmpty, availableHeight: availableHeight.map(Double.init))
    }

    /// 目前字級與內距下，內容高 `contentHeight` 的量測。
    private func metrics(contentHeight: CGFloat) -> ComposerTextMetrics {
        ComposerTextMetrics(
            contentHeight: contentHeight, lineHeight: (font ?? .preferredFont(forTextStyle: .body)).lineHeight,
            verticalInsets: textContainerInset.top + textContainerInset.bottom)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !observesKeyboard {
            observesKeyboard = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        }
        updateAvailableHeight()
        if window != nil, focusesWhenAttached {
            focusesWhenAttached = false
            DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() }
        }
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        keyboardFrameInScreen = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        updateAvailableHeight()
    }

    private func updateAvailableHeight() {
        let measured = measureAvailableHeight()
        guard measured != availableHeight else { return }
        availableHeight = measured
        contentDidChange()
        onAvailableHeightChange?(measured)
    }

    private func measureAvailableHeight() -> CGFloat? {
        guard let window, let screen = window.windowScene?.screen else { return nil }
        var bottom = window.bounds.maxY - window.safeAreaInsets.bottom
        if let keyboardFrameInScreen {
            let overlap = window.convert(keyboardFrameInScreen, from: screen.coordinateSpace).intersection(window.bounds)
            if !overlap.isNull, overlap.height > 0 { bottom = min(bottom, overlap.minY) }
        }
        return max(0, bottom - window.safeAreaInsets.top)
    }

    /// 程式改寫草稿(送出、被拒恢復)時，游標保持與結尾的距離(F6.3)。
    func replaceText(with newText: String) {
        let fromEnd = (text as NSString).length - selectedRange.location - selectedRange.length
        text = newText
        let location = max(0, (newText as NSString).length - max(0, fromEnd))
        selectedRange = NSRange(location: location, length: 0)
        contentDidChange()
    }

    /// 打字、組字、程式改寫草稿或移動游標後呼叫。
    func contentDidChange() {
        needsCaretFollow = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !fillsAvailableSpace else { return }
        updateAvailableHeight()
        // 使用者自己捲動時也會排版：只在內容、游標或大小變了才動捲動位置，不把人拉回游標。
        guard needsCaretFollow || bounds.size != measuredSize, bounds.width > 0 else { return }
        needsCaretFollow = false
        measuredSize = bounds.size
        let contentHeight = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        reportShowsExpand(contentHeight: contentHeight)
        let scrolls = sizing(contentHeight: contentHeight).scrolls || contentHeight > bounds.height + 0.5
        if isScrollEnabled != scrolls { isScrollEnabled = scrolls }
        if scrolls { scrollCaretIntoView(contentHeight: contentHeight) }
    }

    private func reportShowsExpand(contentHeight: CGFloat) {
        let shows = ComposerExpansion.showsExpandButton(metrics(contentHeight: contentHeight), isFocused: isFirstResponder)
        guard shows != reportedShowsExpand else { return }
        reportedShowsExpand = shows
        onShowsExpandChange?(shows)
    }

    /// 讓捲動位置包含游標(組字中是組字尾端)。直接設 `contentOffset`:`scrollRangeToVisible` 在剛開啟內捲時不會動，
    /// `contentSize` 也可能還沒更新，所以用量好的內容高度。
    private func scrollCaretIntoView(contentHeight: CGFloat) {
        guard let caretPosition = selectedTextRange?.end else { return }
        let caret = caretRect(for: caretPosition)
        guard !caret.isNull, !caret.isInfinite, caret.height > 1 else { return }
        let maxOffset = max(0, contentHeight - bounds.height)
        var offset = contentOffset.y
        if caret.maxY + textContainerInset.bottom > offset + bounds.height {
            offset = caret.maxY + textContainerInset.bottom - bounds.height
        } else if caret.minY - textContainerInset.top < offset {
            offset = caret.minY - textContainerInset.top
        }
        offset = min(max(0, offset), maxOffset)
        if offset != contentOffset.y { setContentOffset(CGPoint(x: contentOffset.x, y: offset), animated: false) }
    }

    /// 剪貼簿只有圖片時，貼上是加成附件(#37 故事 33);其他照系統貼上文字。
    override func paste(_ sender: Any?) {
        if pasteAction?() == .attachImages {
            onPasteImages?()
            return
        }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), pasteAction?() == .attachImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// 硬體鍵盤的按鍵 → slash 選單操作(沒有修飾鍵、不在組字中)。
    private func slashMenuKey(for key: UIKey) -> SlashMenuModel.Key? {
        guard markedTextRange == nil, key.modifierFlags.intersection([.command, .shift, .alternate, .control]).isEmpty else { return nil }
        switch key.keyCode {
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardReturnOrEnter, .keyboardTab: return .select
        case .keyboardEscape: return .dismiss
        default: return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var passThrough = Set<UIPress>()
        for press in presses {
            if let key = press.key, let menuKey = slashMenuKey(for: key), slashKey?(menuKey) == true {
                handled.insert(press)
                continue
            }
            if let key = press.key, key.keyCode == .keyboardTab, markedTextRange == nil,
               key.modifierFlags.intersection([.command, .shift, .alternate, .control]).isEmpty, tabKey?() == true {
                handled.insert(press)
                continue
            }
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
    var availableHeight: Binding<CGFloat?> = .constant(nil)
    var showsExpandButton: Binding<Bool> = .constant(false)
    var options: ComposerEditorOptions
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .lineLimit(Int(ComposerSizing.emptyLines)...Int(ComposerSizing.maxLines))
            .textFieldStyle(.plain)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .focused($focused)
            .onChange(of: focused) { isFocused = focused }
            .onChange(of: isFocused) {
                focused = isFocused
                if !options.isExpanded { showsExpandButton.wrappedValue = isFocused }
            }
            .accessibilityIdentifier(options.identifier)
    }
}
#endif
