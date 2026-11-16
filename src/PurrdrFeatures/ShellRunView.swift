import Foundation
import PurrdrCore
import SwiftUI

/// Shell `!` 區塊的顯示規則(行為規格 F5.9)。
struct ShellRunDisplay {
    /// 超過這麼多行就折疊。
    static let foldLimit = 16

    let run: ShellRun

    var command: String { run.command }

    private var output: ShellOutput? {
        if case .recorded(let output) = run.output { output } else { nil }
    }

    private var stdoutLines: [String] { Self.lines(output?.stdout ?? "") }
    private var stderrLines: [String] { Self.lines(output?.stderr ?? "") }

    /// 執行中／無輸出／沒有記錄輸出／N 行輸出(stdout 加 stderr)。
    var statusText: String {
        switch run.output {
        case .running: return String(localized: "Running…")
        case .notRecorded: return String(localized: "No output recorded")
        case .recorded:
            let count = stdoutLines.count + stderrLines.count
            if count == 0 { return String(localized: "No output") }
            return count == 1 ? String(localized: "1 line of output") : String(localized: "\(count) lines of output")
        }
    }

    var isFoldable: Bool { stdoutLines.count + stderrLines.count > Self.foldLimit }

    /// 要顯示的行。折疊時最多 16 行，有 stderr 時一半保留給 stderr(否則 build 錯誤會被進度輸出蓋掉),
    /// stderr 用不完的額度還給 stdout。
    func visible(expanded: Bool) -> (stdout: [String], stderr: [String]) {
        let stdout = stdoutLines
        let stderr = stderrLines
        guard !expanded, isFoldable else { return (stdout, stderr) }
        var stderrShown = min(stderr.count, Self.foldLimit / 2)
        let stdoutShown = min(stdout.count, Self.foldLimit - stderrShown)
        stderrShown = min(stderr.count, Self.foldLimit - stdoutShown)
        return (Array(stdout.prefix(stdoutShown)), Array(stderr.prefix(stderrShown)))
    }

    /// 長按「複製輸出」的內容(stdout 再 stderr)。沒有輸出時 `nil`:複製空字串會清空剪貼簿。
    var copyableOutput: String? {
        guard let output else { return nil }
        let text = [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    var truncationNote: String? {
        output?.isTruncated == true ? String(localized: "Output truncated at 20,000 characters") : nil
    }

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// 終端機風格的 shell 區塊：`$ 指令`(等寬粗體)+ 時間，下方 stdout,stderr 用注意色;超過 16 行折疊。
/// 內容層，不用玻璃。長按(context menu)可複製輸出或指令;不用會吃掉觸控的按鈕包住內容，橫向捲動才不受影響。
struct ShellRunView: View {
    let run: ShellRun
    @State private var expanded = false

    private var display: ShellRunDisplay { ShellRunDisplay(run: run) }

    var body: some View {
        let visible = display.visible(expanded: expanded)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "$ \(run.command)")
                    .font(.system(.footnote, design: .monospaced).bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let date = run.date {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !visible.stdout.isEmpty || !visible.stderr.isEmpty {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !visible.stdout.isEmpty {
                            Text(verbatim: visible.stdout.joined(separator: "\n"))
                                .accessibilityIdentifier("conversation.shell.stdout")
                        }
                        if !visible.stderr.isEmpty {
                            Text(verbatim: visible.stderr.joined(separator: "\n"))
                                .foregroundStyle(.errorText)
                                .accessibilityIdentifier("conversation.shell.stderr")
                        }
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize()
                    .textSelection(.enabled)
                }
                .scrollIndicators(.hidden)
            }
            HStack {
                Text(display.statusText)
                    .accessibilityIdentifier("conversation.shell.status")
                if let note = display.truncationNote {
                    Text(verbatim: "· \(note)")
                }
                Spacer()
                if display.isFoldable {
                    Button { expanded.toggle() } label: {
                        (expanded ? Text("Show Less") : Text("Show All"))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .font(.caption)
                        .accessibilityIdentifier("conversation.shell.toggle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let output = display.copyableOutput {
                Button("Copy Output", systemImage: "document.on.document") { Clipboard.copy(output) }
            }
            Button("Copy Command", systemImage: "document.on.document") { Clipboard.copy(run.command) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.shell")
    }
}
