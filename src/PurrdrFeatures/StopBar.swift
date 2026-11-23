import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 輸入卡片上方置中的工作中膠囊(原型 purrdr-screens 定案版:「● 工作中 0:42 [停止]」;實機回報 2026-11-20):
/// 主色圓點、「Working…／Writing…」與經過時間、停止鈕(長按開強制結束選單);停止中與停止的結果也在這顆膠囊裡。
///
/// 停止鈕是中性的淡填色膠囊，送出維持輸入列唯一的主色主要動作。結果有前導符號與文字(不只靠顏色),
/// 顏色只上在符號(`StopPhase.tone`);出現時有觸覺回饋與 VoiceOver 公告;「已停止」由 model 2 秒後收起。
/// 這顆膠囊就是輸入框上方「工作中」那一樣(`ComposerTopAccessory`),也是畫面上唯一的工作中指示。
struct StopBar: View {
    let model: ConversationModel
    /// 鍵盤讓位時只留一行(#196、`ComposerKeyboardLayout`)。
    var isCompact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        content
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .floatingGlass(in: Capsule())
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stopBar")
            .sensoryFeedback(trigger: model.stopPhase) { _, phase in phase?.feedback }
            .onChange(of: model.stopPhase) { _, phase in
                guard let phase, phase != .stopping else { return }
                AccessibilityNotification.Announcement(phase.title(agent: model.agentName)).post()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stopPhase {
        case nil:
            // AX 字級時停止鈕換到下一行，文字不截斷。
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                workingStatus
                stopButton
            }
        case .stopping?: stoppingButton
        case let phase?: result(phase)
        }
    }

    /// 主色圓點、「Working…」(有即時預覽時「Writing…」)與經過時間。
    private var workingStatus: some View {
        HStack(spacing: 6) {
            // 圓點是裝飾，不跟文字合成一個元素(稽核量文字對比時不把圓點算進去)。
            StatusDot(tone: AgentStatus.working.tone)
            HStack(spacing: 6) {
                Text(model.livePreview == nil ? "Working…" : "Writing…")
                if let since = model.workingSince {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(WorkingElapsed.text(seconds: Int(context.date.timeIntervalSince(since))))
                            .monospacedDigit()
                    }
                }
            }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conversation.working")
            // 背景子 Agent 併進這顆膠囊(#349):點了開狀態 sheet 看清單。
            if let count = model.statusSummary.working?.runningBackgroundAgents, count > 0 {
                Button { model.showsStatusSheet = true } label: {
                    Text(count == 1 ? String(localized: "1 subagent") : String(localized: "\(count) subagents"))
                        .monospacedDigit()
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows the background agents"))
                .accessibilityIdentifier("stopBar.subagents")
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.primary)
    }

    // MARK: - 停止鈕

    /// 點一下送 Esc(不確認);長按開出選單，強制結束要再確認。
    private var stopButton: some View {
        Menu {
            Section {
                Button("Force Quit…", systemImage: "xmark.octagon", role: .destructive) {
                    model.confirmsForceQuit = true
                }
                .disabled(!model.canForceQuit)
                .accessibilityIdentifier("stopBar.forceQuit")
            } footer: {
                // 只說明「需要你」;離線、唯讀時停止列本身就不在。
                if model.agentStatus == .blocked {
                    Text("An agent that needs you can’t be interrupted.")
                }
            }
        } label: {
            Text("Stop")
                .font(.footnote.weight(.semibold))
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
                    .foregroundStyle(Color.primary)
                if !isCompact, let detail = phase.detail {
                    Text(verbatim: detail)
                        .foregroundStyle(.secondaryText)
                }
            }
        } icon: {
            Image(systemName: phase.symbol)
                .foregroundStyle(phase.tone.style)
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
                model.confirmsForceQuit = true
            } label: {
                Text("Force Quit…").frame(minHeight: 44)
            }
            .buttonStyle(StopBarButtonStyle())
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
        case .forceQuitFailed:
            Button {
                model.confirmsForceQuit = true
            } label: {
                Text("Try Again").frame(minHeight: 44)
            }
            .buttonStyle(StopBarButtonStyle())
            .disabled(!model.canForceQuit)
            .accessibilityIdentifier("stopBar.forceQuitRetry")
        case .stopping, .stopped, .needsAnswer:
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

extension View {
    /// 強制結束前的確認(#220):會送 Ctrl-C,destructive 確認，系統提供取消。
    /// 掛在對話畫面上，不放在輸入列(`safeAreaBar` 的內容裡按了不會執行動作)。
    func forceQuitConfirmation(model: ConversationModel) -> some View {
        @Bindable var model = model
        return confirmationDialog(Text("Force Quit \(model.agentName)?"), isPresented: $model.confirmsForceQuit, titleVisibility: .visible) {
            Button("Force Quit", role: .destructive) {
                Task { await model.forceQuit() }
            }
            .accessibilityIdentifier("stopBar.forceQuit.confirm")
        } message: {
            Text("This sends Control-C. Tool calls in progress may be interrupted.")
        }
    }
}

/// 停止列的中性按鈕：淡填色底與主要文字色(玻璃上的 bordered tint 對比不足),destructive 用系統紅，按下變淡。
private struct StopBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // 看得到的是 32pt 高的淡填色膠囊(原型的「停止」),點擊範圍仍是 44pt。
        configuration.label
            .padding(.horizontal, 12)
            .foregroundStyle(configuration.role == .destructive ? Color.destructiveText : Color.primary)
            .background(.fill.tertiary, in: Capsule().inset(by: 6))
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
        case .needsAnswer: String(localized: "\(agent) needs you")
        case .forceQuitFailed: String(localized: "Couldn’t send Force Quit")
        }
    }

    var detail: String? {
        switch self {
        case .stopping, .stopped: nil
        case .stillWorking: String(localized: "Stop was sent, but the agent didn’t stop.")
        case .failed: String(localized: "Check the connection and try again.")
        case .unconfirmed: String(localized: "Stop was sent, but the agent’s status couldn’t be read.")
        case .needsAnswer: String(localized: "Nothing was interrupted. Answer its question instead.")
        case .forceQuitFailed: String(localized: "Check the connection and try again.")
        }
    }

    var symbol: String {
        switch self {
        case .stopping, .stopped: "checkmark.circle.fill"
        case .stillWorking, .needsAnswer: "exclamationmark.circle.fill"
        case .failed, .forceQuitFailed: ErrorLabel.symbolName
        case .unconfirmed: "questionmark.circle.fill"
        }
    }

    var feedback: SensoryFeedback? {
        switch self {
        case .stopping: nil
        case .stopped: .success
        case .stillWorking, .unconfirmed, .needsAnswer: .warning
        case .failed, .forceQuitFailed: .error
        }
    }
}
