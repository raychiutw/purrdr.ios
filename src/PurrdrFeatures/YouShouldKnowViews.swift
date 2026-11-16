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
                            .foregroundStyle(.secondary)
                        Text(verbatim: entry.note.line)
                            .font(.body)
                        if let explanation = entry.note.explanation, entry.note.kind == .explained {
                            Text(verbatim: explanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Button("Go to Chat", systemImage: "arrow.right.circle") {
                            dismiss()
                            go(entry.route)
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
            .foregroundStyle(.secondary)
            Text(verbatim: note.line)
                .font(.subheadline)
                .accessibilityIdentifier("youShouldKnow.note")
            if note.kind == .explained, let explanation = note.explanation {
                Text(verbatim: explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .youShouldKnowConsent(model)
    }

    @ViewBuilder
    private var actions: some View {
        if note.canLearnMore {
            Button("Learn More") { Task { await model.perform(.learnMore, on: note) } }
                .frame(minHeight: 44)
                .accessibilityIdentifier("youShouldKnow.learnMore")
        }
        Button(note.kind == .explained ? "Got It" : "I Knew That") { Task { await model.perform(.knewIt, on: note) } }
            .frame(minHeight: 44)
            .accessibilityIdentifier("youShouldKnow.knewIt")
        Button("Discuss in Chat") {
            // 先放進輸入框(不改主機),再當作「早就知道」寫回(行為規格 F17)。
            conversation.insertIntoDraft(note.discussionDraft)
            Task { await model.perform(.knewIt, on: note) }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("youShouldKnow.discuss")
        Button("Dismiss") { Task { await model.perform(.dismiss, on: note) } }
            .frame(minHeight: 44)
            .accessibilityIdentifier("youShouldKnow.dismiss")
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
