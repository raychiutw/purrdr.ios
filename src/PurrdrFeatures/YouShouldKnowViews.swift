import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 列表標題下一行的「✦ N 則註記」(#37 故事 49)。點了開註記清單。
struct YouShouldKnowListRow: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label {
                if count == 1 {
                    Text("1 note for you")
                } else {
                    Text("\(count) notes for you")
                }
            } icon: {
                Image(systemName: "sparkle")
            }
            .font(.subheadline)
        }
        .accessibilityIdentifier("youShouldKnow.summary")
    }
}

/// 註記清單(sheet):所有主機的註記(選取中主機在前、每台新→舊),每則可「前往」所屬聊天(#37 故事 50)。
struct YouShouldKnowListView: View {
    let entries: [MergedAgentListModel.NoteEntry]
    let go: (ChatRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: entry.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondaryText)
                        Text(verbatim: entry.note.line)
                            .font(.body)
                        if let explanation = entry.note.explanation, entry.note.kind == .explained {
                            Text(verbatim: explanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondaryText)
                        }
                        Button {
                            dismiss()
                            go(entry.route)
                        } label: {
                            // 觸控目標 ≥ 44pt(frame 放在 label 裡才會撐大可點範圍,#35)。
                            Label("Go to Chat", systemImage: "arrow.right.circle")
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("youShouldKnow.go.\(entry.route.host.storedValue)/\(entry.route.paneID)")
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("You Should Know")
            .accessibilityIdentifier("sheet.youShouldKnow")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("sheet.done")
                }
            }
        }
    }
}

/// 輸入列上方的註記(#37 故事 50):內容層卡片，動作「深入了解」「早就知道」「在聊天中討論」「略過」。
struct YouShouldKnowNoteView: View {
    let note: YouShouldKnowNote
    let model: YouShouldKnowModel
    let conversation: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: note.tag ?? String(localized: "You should know"))
                    .font(.footnote.weight(.semibold))
            } icon: {
                Image(systemName: "sparkle")
            }
            .foregroundStyle(.secondaryText)
            Text(verbatim: note.line)
                .font(.subheadline)
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 4) { actions }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .disabled(model.isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 同 slash 選單：不透明的 `.background` + `.separator` 邊(#67 audit)。原本的 `.background.secondary`(#F2F2F7)上
        // tint 文字按鈕(#D91E36)只有 4.49:1;半透明填色則會透出後面捲動中的訊息。
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .youShouldKnowConsent(model)
    }

    @ViewBuilder
    private var actions: some View {
        if note.canLearnMore {
            Button { Task { await model.perform(.learnMore, on: note) } } label: { HitTarget("Learn More") }
                .accessibilityIdentifier("youShouldKnow.learnMore")
        }
        Button { Task { await model.perform(.knewIt, on: note) } } label: {
            HitTarget(note.kind == .explained ? "Got It" : "I Knew That")
        }
        .accessibilityIdentifier("youShouldKnow.knewIt")
        Button {
            // 先放進輸入框(不改主機),再當作「早就知道」寫回(行為規格 F17)。
            conversation.insertIntoDraft(note.discussionDraft)
            Task { await model.perform(.knewIt, on: note) }
        } label: {
            HitTarget("Discuss in Chat")
        }
        .accessibilityIdentifier("youShouldKnow.discuss")
        Button { Task { await model.perform(.dismiss, on: note) } } label: { HitTarget("Dismiss") }
            .accessibilityIdentifier("youShouldKnow.dismiss")
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
        .buttonStyle(.plain)
        // 同完整卡片：內容層、不透明底(#67 audit)。
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
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
            Text("To mark notes, Purrdr updates Claude Code’s notes file in ~/.claude/plugins/store as \(model.pendingConsent?.user ?? ""). You can undo Purrdr’s changes in Settings.")
        }
    }
}
