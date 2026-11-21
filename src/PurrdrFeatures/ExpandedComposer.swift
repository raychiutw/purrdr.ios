import PurrdrAgentFeatures
import SwiftUI

/// 展開編輯(#142):同一份草稿與同一個 `ComposerTextEditor`(組字中 Return 只確認選字);附件列在上，
/// 「加入圖片」「完成」與送出鈕在底部，鍵盤出現時停在鍵盤上方。送出或「完成」都收回到對話。
struct ExpandedComposer: View {
    @Bindable var model: ConversationModel
    let placeholder: String
    let returnSends: Bool
    let collapse: () -> Void
    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty && model.typedAnswer == nil {
                AttachmentStrip(model: model, identifierPrefix: "composer.expanded")
            }
            editor
        }
        .padding([.horizontal, .top])
        .safeAreaInset(edge: .bottom) { actions }
        .presentationDetents([.large])
    }

    private var editor: some View {
        ComposerTextEditor(
            text: $model.draft, isFocused: $isFocused,
            options: ComposerEditorOptions(
                isExpanded: true, identifier: "composer.expanded.text",
                placeholder: placeholder, returnSends: returnSends, canSend: model.canSend,
                // slash 選單只在輸入列顯示：這裡不攔截它的按鍵。
                slashKey: { _ in false },
                onComposingChange: { model.isComposingDraft = $0 },
                pasteAction: { [model] in ComposerPasteHandler.action(for: model) },
                onPasteImages: { [model] in ComposerPasteHandler.attachPasteboardImages(to: model) },
                onSend: send
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if model.draft.isEmpty {
                Text(verbatim: placeholder)
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if model.canAttachImages && model.typedAnswer == nil {
                    AddImageButton(model: model, identifier: "composer.expanded.addImage")
                }
                if let sendWhenDone = model.sendWhenDone, model.typedAnswer == nil {
                    SendWhenDoneToggle(model: sendWhenDone, identifier: "composer.expanded.sendWhenDone", isInCard: false)
                }
                Spacer()
                Button(action: collapse) {
                    Text("Done")
                        .padding(.horizontal, 8)
                        .frame(minHeight: 30)
                }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
                .accessibilityIdentifier("composer.expanded.done")
                ComposerSendButton(model: model, identifier: "composer.expanded.send", action: send)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send() {
        collapse()
        Task { await model.send() }
    }
}
