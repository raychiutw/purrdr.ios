import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 變更頁(#310,原型 `#t310-a`「清單 → 單檔 diff」):分支與檔案數、變更清單(種類、+/−),點檔案推入單檔 diff。
/// 有評論時底部固定「N 則評論，共 M 個檔案 · 送出評論」。
struct ChangesView: View {
    let model: ChangesModel
    /// 送出評論：組好的訊息交給聊天(畫面先回到聊天，撤回倒數才看得到)。
    let submit: (String) -> Void

    var body: some View {
        content
            .navigationTitle("Changes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) { ChangesReviewBar(model: model, submit: submit) }
            .task { if model.phase == .loading { await model.load() } }
            .refreshable { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("changes.loading")
        case .failed(let problem):
            ChangesProblemView(problem: problem) { Task { await model.load() } }
        case .loaded:
            if model.files.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working directory matches the last commit."))
                    .accessibilityIdentifier("changes.empty")
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.files) { file in
                    // 目的地直接寫在連結上：變更頁本身是以 `navigationDestination(isPresented:)` 推入的，
                    // 再登記 value 型的目的地會讓堆疊多推一層。
                    NavigationLink {
                        ChangesFileView(model: model, path: file.path, submit: submit)
                    } label: {
                        ChangedFileRow(file: file, commentCount: model.comments.count { $0.path == file.path })
                    }
                    .accessibilityIdentifier("changes.file.\(file.path)")
                }
            } header: {
                Text(verbatim: summary)
                    .textCase(nil)
                    .accessibilityIdentifier("changes.summary")
            }
        }
        .appGroupedList()
        .accessibilityIdentifier("changes.list")
    }

    /// 「master · 3 個檔案」;detached HEAD 時只有檔案數。
    private var summary: String {
        let count = String(localized: "\(model.files.count) files")
        guard let branch = model.branch else { return count }
        return "\(branch) · \(count)"
    }
}

/// 變更清單的一列：種類標記(字母，不只靠顏色)、檔名與資料夾、+/−。
private struct ChangedFileRow: View {
    let file: ChangesModel.ChangedFile
    let commentCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ChangeKindBadge(kind: file.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                if let folder {
                    Text(verbatim: folder)
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if commentCount > 0 {
                Label { Text(verbatim: "\(commentCount)") } icon: { Image(systemName: "text.bubble") }
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
            if let stats = file.stats {
                ChangeStatsText(stats: stats)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var name: String { file.path.split(separator: "/").last.map(String.init) ?? file.path }

    private var folder: String? {
        let parts = file.path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    private var accessibilityText: String {
        var parts = [file.path, ChangeKindBadge.title(file.kind)]
        if let stats = file.stats {
            parts.append(String(localized: "\(stats.added) added, \(stats.removed) removed"))
        }
        if commentCount > 0 { parts.append(String(localized: "\(commentCount) comments")) }
        return parts.joined(separator: ", ")
    }
}

/// 種類標記:M／A／D／U 字母加底色(色盲也看得出)。
struct ChangeKindBadge: View {
    let kind: GitChangeKind

    var body: some View {
        Text(verbatim: letter)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(.primary)
            .frame(minWidth: 22, minHeight: 22)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(Text(verbatim: Self.title(kind)))
    }

    private var letter: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .untracked: "U"
        }
    }

    static func title(_ kind: GitChangeKind) -> String {
        switch kind {
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .deleted: String(localized: "Deleted")
        case .untracked: String(localized: "Untracked")
        }
    }
}

private struct ChangeStatsText: View {
    let stats: GitDiffStats

    var body: some View {
        HStack(spacing: 4) {
            if stats.added > 0 { Text(verbatim: "+\(stats.added)").fontWeight(.semibold) }
            if stats.removed > 0 { Text(verbatim: "−\(stats.removed)").foregroundStyle(.secondaryText) }
        }
        .font(.system(.footnote, design: .monospaced))
    }
}

/// 讀不到變更的說明(不是 git repo、Agent 換了資料夾、要更新主機服務…)。
private struct ChangesProblemView: View {
    let problem: ChangesProblem
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if case .hostServiceUpdateRequired(let installed) = problem {
                HostServiceCommandRows(
                    message: "Update the Purrdr host service to see changes. Run this on the computer:",
                    commands: HostServiceUpdates.commands(installed: installed ?? "0.0.0"), identifier: "changes.update")
            } else {
                Text(verbatim: message)
            }
        } actions: {
            if problem == .failed || problem == .agentMoved || problem == .gitNotInstalled {
                Button("Try Again", action: retry)
                    .frame(minHeight: 44)
            }
        }
        .accessibilityIdentifier("changes.problem")
    }

    private var symbol: String {
        if case .failed = problem { return ErrorLabel.symbolName }
        if case .hostServiceUpdateRequired = problem { return "arrow.down.circle" }
        return "plus.forwardslash.minus"
    }

    private var title: LocalizedStringKey {
        switch problem {
        case .unsupported: "Not Available on This Host"
        case .notGitRepository: "Not a Git Repository"
        case .agentMoved: "The Agent Moved"
        case .gitNotInstalled: "Git Isn’t Installed"
        case .hostServiceUpdateRequired: "Update the Host Service"
        case .failed: "Couldn’t Load Changes"
        }
    }

    private var message: String {
        switch problem {
        case .unsupported: String(localized: "This host can’t show git changes yet.")
        case .notGitRepository: String(localized: "This folder isn’t tracked by git, so there are no changes to show.")
        case .agentMoved: String(localized: "The agent is no longer working in this folder. Go back and open the changes again.")
        case .gitNotInstalled: String(localized: "This computer doesn’t have git yet. After you install it, tap Try Again.")
        case .hostServiceUpdateRequired: ""
        case .failed: String(localized: "Check the connection and try again.")
        }
    }
}

/// 單檔 diff:點行選取並寫評論，評論卡片插在那一行下面。
struct ChangesFileView: View {
    let model: ChangesModel
    let path: String
    let submit: (String) -> Void
    @State private var editing: EditingComment?

    var body: some View {
        content
            .navigationTitle(Text(verbatim: path.split(separator: "/").last.map(String.init) ?? path))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) { ChangesReviewBar(model: model, submit: submit) }
            .task(id: path) { await model.loadDiff(of: path) }
            .sheet(item: $editing) { comment in
                ChangesCommentEditor(model: model, path: path, line: comment.line)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.diff(of: path) {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let problem):
            ChangesProblemView(problem: problem) { Task { await model.loadDiff(of: path) } }
        case .omitted(let reason):
            ContentUnavailableView(omissionTitle(reason), systemImage: "doc", description: Text(omissionMessage(reason)))
                .accessibilityIdentifier("changes.omitted")
        case .lines(let lines):
            if lines.isEmpty {
                ContentUnavailableView("No Text Changes", systemImage: "doc", description: Text("Only the file mode or an empty file changed."))
            } else {
                diff(lines)
            }
        }
    }

    private func diff(_ lines: [GitDiffLine]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DiffLineRow(line: line, isSelected: editing?.line.id == line.id || model.comment(on: line, in: path) != nil) {
                        editing = EditingComment(line: line)
                    }
                    if let comment = model.comment(on: line, in: path) {
                        ReviewCommentCard(comment: comment) { editing = EditingComment(line: line) }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("changes.diff")
    }

    private func omissionTitle(_ reason: GitDiffOmission) -> LocalizedStringKey {
        switch reason {
        case .binary: "Binary File"
        case .tooLarge: "Diff Too Large"
        case .excluded: "Not Shown"
        }
    }

    private func omissionMessage(_ reason: GitDiffOmission) -> LocalizedStringKey {
        switch reason {
        case .binary: "This file isn’t text, so there’s no diff to show."
        case .tooLarge: "This diff is too large to show on this device."
        case .excluded: "Files that may hold credentials aren’t read."
        }
    }
}

private struct EditingComment: Identifiable {
    let line: GitDiffLine
    var id: Int { line.id }
}

/// diff 的一行：行號、+/− 與內容(換行顯示，不橫捲)。可評論的行整列可點(點行號選行)。
private struct DiffLineRow: View {
    let line: GitDiffLine
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        if line.isCommentable {
            Button(action: select) { row }
                .buttonStyle(.plain)
                .accessibilityIdentifier("changes.line.\(line.id)")
                .accessibilityLabel(Text(verbatim: accessibilityText))
                .accessibilityHint(Text("Adds a comment on this line."))
        } else {
            row
                .accessibilityLabel(Text(verbatim: line.text))
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: line.number.map(String.init) ?? "")
                .foregroundStyle(.secondaryText)
                .frame(minWidth: 36, alignment: .trailing)
            Text(verbatim: line.kind == .hunkHeader || line.kind == .note ? line.text : line.diffText)
                .foregroundStyle(style)
                .fontWeight(line.kind == .added ? .semibold : .regular)
                .strikethrough(line.kind == .removed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(isSelected ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
    }

    private var style: AnyShapeStyle {
        switch line.kind {
        case .added, .context: AnyShapeStyle(.primary)
        case .removed, .hunkHeader, .note: AnyShapeStyle(.secondaryText)
        }
    }

    private var accessibilityText: String {
        let number = line.number.map { String(localized: "Line \($0)") } ?? ""
        let kind: String = switch line.kind {
        case .added: String(localized: "Added")
        case .removed: String(localized: "Removed")
        default: ""
        }
        return [number, kind, line.text].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// 插在行下面的評論卡片;點它再編輯。
private struct ReviewCommentCard: View {
    let comment: GitReviewComment
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Comment · Line \(comment.line.number ?? 0)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                Text(verbatim: comment.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(AppSurface.page, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("changes.comment.\(comment.line.id)")
    }
}

/// 寫評論的 sheet:引用那一行，取消／儲存;已有評論時可刪除。
private struct ChangesCommentEditor: View {
    let model: ChangesModel
    let path: String
    let line: GitDiffLine
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: line.diffText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondaryText)
                }
                Section {
                    TextField("Comment", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityIdentifier("changes.comment.field")
                }
                if model.comment(on: line, in: path) != nil {
                    Section {
                        Button("Delete Comment", role: .destructive) {
                            model.setComment("", on: line, in: path)
                            dismiss()
                        }
                        .accessibilityIdentifier("changes.comment.delete")
                    }
                }
            }
            .appGroupedList()
            .navigationTitle(Text("Line \(line.number ?? 0)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setComment(text, on: line, in: path)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("changes.comment.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            text = model.comment(on: line, in: path)?.body ?? ""
            focused = true
        }
    }
}

/// 底部固定列：「N 則評論，共 M 個檔案」與「送出評論」。沒有評論時不顯示;聊天不能送出時停用並說明。
private struct ChangesReviewBar: View {
    let model: ChangesModel
    let submit: (String) -> Void

    var body: some View {
        if !model.comments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("\(model.comments.count) comments in \(model.commentedFileCount) files")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("changes.review.summary")
                    Button {
                        if let message = model.takeReview() { submit(message) }
                    } label: {
                        Label("Send Comments", systemImage: "paperplane.fill")
                            .frame(minHeight: 44)
                    }
                    .filledProminentButtonStyle()
                    .disabled(!model.canSendReview)
                    .accessibilityIdentifier("changes.review.send")
                }
                if !model.canSendReview {
                    Text("You can’t send to this agent right now.")
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
