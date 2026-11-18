import PurrdrCore
import SwiftUI

/// 列表底部的 Claude 用量(行為規格 F18、DESIGN.md「Agent 列表」)。
///
/// 同意前是「顯示 Claude 用量」按鈕，點了先檢查主機，再以 alert 說明會改什麼、以哪個使用者;
/// 同意後是 5h／Week 兩列(剩餘比例、進度條、重置時間),點擊打開選單切換已用比例或關閉。
/// 獨立於列表，放進 `AgentListView` 的 footer。前景、可見時約每 5 秒讀一次。
public struct ClaudeUsageFooter: View {
    @Bindable var model: ClaudeUsageModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: ClaudeUsageModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("claudeUsage.message")
            }
        }
        .alert("Show Claude Usage?", isPresented: confirming) {
            Button("Change Settings") { Task { await model.confirm() } }
            Button("Cancel", role: .cancel) { model.cancelConsent() }
        } message: {
            Text(consentMessage)
        }
        .task(id: scenePhase == .active && model.state == .on) {
            guard scenePhase == .active, model.state == .on else { return }
            await model.liveUpdates.attach()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .off, .confirming:
            Button {
                Task { await model.requestUsage() }
            } label: {
                Label("Show Claude Usage", systemImage: "gauge.with.dots.needle.33percent")
            }
            .accessibilityIdentifier("claudeUsage.show")
        case .checking:
            progress("Checking the host…")
        case .installing:
            progress("Changing the host’s Claude settings…")
        case .turningOff:
            progress("Restoring the host’s Claude settings…")
        case .on:
            usageMenu
        }
    }

    private func progress(_ title: LocalizedStringKey) -> some View {
        Label {
            Text(title).foregroundStyle(.secondaryText)
        } icon: {
            ProgressView()
        }
    }

    /// 標題列右側是選項選單：切換剩餘／已用，或關閉並還原主機設定。
    private var usageMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude Usage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                Spacer()
                Menu {
                    Picker("Show", selection: $model.display) {
                        Text("Show Remaining").tag(ClaudeUsageModel.Display.remaining)
                        Text("Show Used").tag(ClaudeUsageModel.Display.used)
                    }
                    Button("Turn Off Claude Usage", systemImage: "arrow.uturn.backward", role: .destructive) {
                        Task { await model.turnOff() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Claude Usage Options"))
                .accessibilityIdentifier("claudeUsage.menu")
            }
            usageRows
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Label("Waiting for Claude Code to report usage", systemImage: "gauge.with.dots.needle.0percent")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(rows) { row in
                ClaudeUsageRowView(row: row, display: model.display)
                    .accessibilityIdentifier(row.window == .fiveHour ? "claudeUsage.row.fiveHour" : "claudeUsage.row.week")
            }
            if let asOf = model.asOf {
                Text("As of \(asOf, format: .dateTime.hour().minute())")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    private var confirming: Binding<Bool> {
        Binding {
            if case .confirming = model.state { return true }
            return false
        } set: { _ in
            // alert 關閉時 SwiftUI 會先設 false 再執行按鈕;狀態交給按鈕(確認／取消)處理，否則「確認」會先被當成取消。
        }
    }

    private var consentMessage: String {
        guard case .confirming(let user) = model.state else { return "" }
        return """
            Claude Code shares plan usage only with its status line. To show it here, Purrdr will change \
            ~/.claude/settings.json on this host as the user “\(user)”: the status line command becomes \
            ~/.purrdr/claude-usage/statusline.sh, which saves the usage and then runs your current status line. \
            Turning this off restores your original settings.
            """
    }
}

/// 一個用量視窗：名稱、比例、進度條、重置時間。
struct ClaudeUsageRowView: View {
    let row: ClaudeUsageRow
    let display: ClaudeUsageModel.Display

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(display == .remaining ? "\(row.percent)% left" : "\(row.percent)% used")
                    .font(.subheadline.monospacedDigit())
            }
            ProgressView(value: row.fraction)
                .accessibilityHidden(true)
            if let resetsAt = row.resetsAt {
                Text("Resets \(resetsAt, format: Self.resetFormat(resetsAt))")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch row.window {
        case .fiveHour: "5h"
        case .week: "Week"
        }
    }

    /// 一天內只顯示時間，否則加上星期。時間依裝置地區與 12/24 小時制。
    static func resetFormat(_ date: Date, now: Date = Date()) -> Date.FormatStyle {
        date.timeIntervalSince(now) < 24 * 3600 ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
    }
}
