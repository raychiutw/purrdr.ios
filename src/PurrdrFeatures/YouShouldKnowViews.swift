import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 輸入列上方的註記(#37 故事 50):內容層卡片，動作「深入了解」「早就知道」「在聊天中討論」「略過」。
struct YouShouldKnowNoteView: View {
    let note: YouShouldKnowNote
    let model: YouShouldKnowModel
    let conversation: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 略過放標題列右上的 ✕,其他動作排成一列：不直排佔掉對話可視區。
            HStack(alignment: .center, spacing: 8) {
                Label {
                    Text(verbatim: note.tag ?? String(localized: "You should know"))
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkle")
                }
                .foregroundStyle(.secondaryText)
                Spacer(minLength: 0)
                Button { Task { await model.perform(.dismiss, on: note) } } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(model.isWorking)
                .accessibilityLabel(Text("Dismiss"))
                .accessibilityIdentifier("youShouldKnow.dismiss")
                .padding(.vertical, -12)
                .padding(.trailing, -12)
            }
            Text(verbatim: note.line)
                .font(.subheadline)
                // AX 字級時輸入列上方高度不夠，不讓註記被壓成一行截字(#249),讓對話讓出空間。
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("youShouldKnow.note")
            if note.kind == .explained, let explanation = note.explanation {
                Text(verbatim: explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            if let message = model.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
            // 放不下一列時，第一個動作之外收進「更多」選單，不改成直排。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { actions }
                HStack(spacing: 16) {
                    primaryAction
                    Menu { secondaryActions } label: { HitTarget("More") }
                        .accessibilityIdentifier("youShouldKnow.more")
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .disabled(model.isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 同 slash 選單：不透明的 `.background` + `.separator` 邊(#67 audit)。原本的 `.background.secondary`(#F2F2F7)上
        // tint 文字按鈕(#D91E36)只有 4.49:1;半透明填色則會透出後面捲動中的訊息。
        .background(AppSurface.page, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .youShouldKnowConsent(model)
    }

    @ViewBuilder
    private var actions: some View {
        if note.canLearnMore {
            learnMore
        }
        knewIt
        discuss
    }

    /// 放不下一列時留在外面的動作。
    @ViewBuilder
    private var primaryAction: some View {
        if note.canLearnMore { learnMore } else { knewIt }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if note.canLearnMore {
            knewIt
        }
        discuss
    }

    private var learnMore: some View {
        Button { Task { await model.perform(.learnMore, on: note) } } label: { HitTarget("Learn More") }
            .accessibilityIdentifier("youShouldKnow.learnMore")
    }

    private var knewIt: some View {
        Button { Task { await model.perform(.knewIt, on: note) } } label: {
            HitTarget(note.kind == .explained ? "Got It" : "I Knew That")
        }
        .accessibilityIdentifier("youShouldKnow.knewIt")
    }

    private var discuss: some View {
        Button {
            // 先放進輸入框(不改主機),再當作「早就知道」寫回(行為規格 F17)。
            conversation.insertIntoDraft(note.discussionDraft)
            Task { await model.perform(.knewIt, on: note) }
        } label: {
            HitTarget("Discuss in Chat")
        }
        .accessibilityIdentifier("youShouldKnow.discuss")
    }
}

/// 鍵盤出現、空間不夠時收成一行的註記(#196):收起鍵盤後仍是一行，點了才收起鍵盤、換回完整卡片(含動作)。
struct YouShouldKnowCompactNoteView: View {
    let note: YouShouldKnowNote
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            Label {
                Text(verbatim: note.line)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "sparkle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, minHeight: ComposerKeyboardLayout.compactHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.pressableRow(cornerRadius: 16))
        // 同完整卡片：內容層、不透明底(#67 audit)。
        .background(AppSurface.page, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .accessibilityLabel(Text("\(note.tag ?? String(localized: "You should know")): \(note.line)"))
        .accessibilityHint(Text("Shows the whole note."))
        .accessibilityIdentifier("youShouldKnow.compact")
    }
}

extension View {
    /// 第一次對註記動作時的同意(ADR-0002):說明會改哪個檔、以哪個使用者，可在設定撤掉。
    func youShouldKnowConsent(_ model: YouShouldKnowModel) -> some View {
        alert("Update Notes on This Host?", isPresented: Binding(get: { model.pendingConsent != nil }, set: { _ in })) {
            Button("Cancel", role: .cancel) { model.cancelConsent() }
            Button("Allow") { Task { await model.confirmConsent() } }
                .accessibilityIdentifier("youShouldKnow.allow")
        } message: {
            Text("To mark notes, Purrdr updates Claude Code’s notes on this host, as \(model.pendingConsent?.user ?? ""). You can undo Purrdr’s changes in Settings.")
        }
    }
}
