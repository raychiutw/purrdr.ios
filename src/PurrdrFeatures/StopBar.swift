import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 輸入卡片最上面的停止列(#220):停止鈕(長按開強制結束選單)、停止中、停止的結果。
///
/// 停止鈕是中性的淡填色鈕，送出維持輸入列唯一的紅底主要動作。結果有前導符號與文字(不只靠顏色),
/// 出現時有觸覺回饋與 VoiceOver 公告;「已停止」由 model 2 秒後收起，其他結果留到處理或狀態改變。
struct StopBar: View {
    let model: ConversationModel
    /// 鍵盤讓位時只留一行(#196、`ComposerKeyboardLayout`)。
    var isCompact = false
    @State private var confirmsForceQuit = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stopBar")
            .sensoryFeedback(trigger: model.stopPhase) { _, phase in phase?.feedback }
            .onChange(of: model.stopPhase) { _, phase in
                guard let phase, phase != .stopping else { return }
                AccessibilityNotification.Announcement(phase.title(agent: model.agentName)).post()
            }
            .confirmationDialog(
                Text("Force Quit \(model.agentName)?"), isPresented: $confirmsForceQuit, titleVisibility: .visible
            ) {
                Button("Force Quit", role: .destructive) {
                    Task { await model.forceQuit() }
                }
                .accessibilityIdentifier("stopBar.forceQuit.confirm")
            } message: {
                Text("This sends Control-C. Tool calls in progress may be interrupted.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stopPhase {
        case nil: stopButton
        case .stopping?: stoppingButton
        case let phase?: result(phase)
        }
    }

    // MARK: - 停止鈕

    /// 點一下送 Esc(不確認);長按開出選單，強制結束要再確認。
    private var stopButton: some View {
        Menu {
            Section {
                Button("Force Quit…", systemImage: "xmark.octagon", role: .destructive) {
                    confirmsForceQuit = true
                }
                .disabled(!model.canForceQuit)
                .accessibilityIdentifier("stopBar.forceQuit")
            } footer: {
                if !model.canForceQuit {
                    Text("An agent that needs you can’t be interrupted.")
                }
            }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .contentShape(.rect)
        } primaryAction: {
            Task { await model.stop() }
        }
        .menuStyle(.button)
        .buttonStyle(StopBarButtonStyle())
        .accessibilityLabel(Text("Stop \(model.agentName)"))
        .accessibilityHint(Text("Interrupts the agent’s current turn. Touch and hold for Force Quit."))
        .accessibilityIdentifier("stopBar.stop")
    }

    private var stoppingButton: some View {
        Button {} label: {
            HStack(spacing: 6) {
                ProgressView()
                Text("Stopping…")
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
        }
        .buttonStyle(StopBarButtonStyle())
        .disabled(true)
        .accessibilityLabel(Text("Stopping…"))
        .accessibilityIdentifier("stopBar.stopping")
    }

    // MARK: - 結果

    private func result(_ phase: StopPhase) -> some View {
        // AX 字級時動作鈕換到文字下方，不截斷。
        let layout = dynamicTypeSize.isAccessibilitySize && !isCompact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return layout {
            resultText(phase)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                action(phase)
                if phase != .stopped {
                    closeButton
                }
            }
        }
        .padding(.leading, 8)
    }

    private func resultText(_ phase: StopPhase) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: phase.title(agent: model.agentName))
                    .foregroundStyle(phase.color)
                if !isCompact, let detail = phase.detail {
                    Text(verbatim: detail)
                        .foregroundStyle(.secondaryText)
                }
            }
        } icon: {
            Image(systemName: phase.symbol)
                .foregroundStyle(phase.color)
        }
        .font(.footnote)
        .lineLimit(isCompact ? 1 : nil)
        .fixedSize(horizontal: false, vertical: !isCompact)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stopBar.result")
    }

    @ViewBuilder
    private func action(_ phase: StopPhase) -> some View {
        switch phase {
        case .stillWorking:
            Button(role: .destructive) {
                confirmsForceQuit = true
            } label: {
                Text("Force Quit…").frame(minHeight: 44)
            }
            .buttonStyle(StopBarButtonStyle(foreground: .errorText))
            .disabled(!model.canForceQuit)
            .accessibilityIdentifier("stopBar.forceQuitResult")
        case .failed:
            Button {
                Task { await model.stop() }
            } label: {
                Text("Try Again").frame(minHeight: 44)
            }
            .buttonStyle(StopBarButtonStyle())
            .accessibilityIdentifier("stopBar.retry")
        case .unconfirmed:
            Button {
                Task { await model.reload() }
            } label: {
                Text("Reload").frame(minHeight: 44)
            }
            .buttonStyle(StopBarButtonStyle())
            .accessibilityIdentifier("stopBar.reload")
        case .stopping, .stopped:
            EmptyView()
        }
    }

    private var closeButton: some View {
        Button {
            model.dismissStopResult()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondaryText)
        .accessibilityLabel(Text("Close"))
        .accessibilityIdentifier("stopBar.dismiss")
    }
}

/// 停止列的中性按鈕：淡填色底與主要文字色(玻璃上的 bordered tint 對比不足),按下變淡。
private struct StopBarButtonStyle: ButtonStyle {
    var foreground: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .foregroundStyle(foreground)
            .background(.fill.tertiary, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

extension StopPhase {
    /// 結果的主要文字(也是 VoiceOver 公告)。
    func title(agent: String) -> String {
        switch self {
        case .stopping: String(localized: "Stopping…")
        case .stopped: String(localized: "Stopped")
        case .stillWorking: String(localized: "\(agent) is still working")
        case .failed: String(localized: "Couldn’t send Stop")
        case .unconfirmed: String(localized: "Couldn’t confirm it stopped")
        }
    }

    var detail: String? {
        switch self {
        case .stopping, .stopped: nil
        case .stillWorking: String(localized: "Stop was sent, but the agent didn’t stop.")
        case .failed: String(localized: "Check the connection and try again.")
        case .unconfirmed: String(localized: "Stop was sent, but the agent’s status couldn’t be read.")
        }
    }

    var symbol: String {
        switch self {
        case .stopping, .stopped: "checkmark.circle.fill"
        case .stillWorking: "exclamationmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unconfirmed: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .stopping, .stopped: .successText
        case .stillWorking, .unconfirmed: .warningText
        case .failed: .errorText
        }
    }

    var feedback: SensoryFeedback? {
        switch self {
        case .stopping: nil
        case .stopped: .success
        case .stillWorking, .unconfirmed: .warning
        case .failed: .error
        }
    }
}
