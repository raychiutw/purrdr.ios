import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// 模型選擇的停用原因(#561 第二步):同一套規則,表格測試。
@Suite("Agent 控制:模型選擇停用原因")
struct AgentControlsModelChoiceLockTests {
    private static func dialect(_ name: String) -> ScreenDialect { AgentCatalog.profile(forHerdrName: name).screen }

    @Test("優先序:方言做不到 > 唯讀 > 離線 > 等你回覆 > 工作中 > 可選")
    func lockTable() {
        typealias Link = AgentControls.Link
        let rows: [(String, Link, AgentControls.ModelChoiceLock?)] = [
            ("claude", Link(hasAgent: true, agentStatus: .done), nil),
            ("claude", Link(isReadOnly: true, hasAgent: true, agentStatus: .done), .readOnlyDevice),
            ("claude", Link(isReadOnly: true, isOffline: true, hasAgent: true), .readOnlyDevice),
            ("claude", Link(isOffline: true, hasAgent: true), .offline),
            ("claude", Link(hasAgent: true, agentStatus: .blocked), .waitingForYou),
            ("claude", Link(hasAgent: true, hasPrompt: true, agentStatus: .done), .waitingForYou),
            ("claude", Link(hasAgent: true, agentStatus: .working), .working),
            // 還沒讀到 Agent:方言的原因不算
            ("codex", Link(hasAgent: false, agentStatus: .done), nil),
            ("codex", Link(hasAgent: true, agentStatus: .done), .agentLacksFeature),
            // 方言做不到的優先於連線狀態
            ("codex", Link(isReadOnly: true, hasAgent: true), .agentLacksFeature),
        ]
        for (name, link, expected) in rows {
            let controls = AgentControls(dialect: Self.dialect(name), metadata: TranscriptMetadata(), link: link)
            #expect(controls.modelChoiceLock == expected, "\(name) \(link)")
        }
    }
}

/// 切換程序(#561 第二步):不搭聊天 model,用假的 host 直接驗按鍵序列與結果。
@MainActor
@Suite("Agent 控制:切換程序")
struct AgentControlSwitcherTests {
    @MainActor
    final class FakeHost: AgentControlSwitchingHost {
        var controls: AgentControls
        var isReadOnly = false
        var isOffline = false
        var canChooseModel = true
        var panel: SlashPanel?
        var isOperatingPanel = false
        var isWatchingPanel = true
        var operated: [SlashPanel.Input] = []
        var commands: [String] = []
        var keysSent: [String] = []
        var notices: [SendNotice?] = []
        var feedbacks: [HapticFeedback] = []
        var screenModes: [AgentPermissionMode?] = []
        var recorded: [AgentPermissionMode] = []
        var cycle: [AgentPermissionMode]?
        var commandSucceeds = true

        init(controls: AgentControls) { self.controls = controls }

        var permissionModeCycle: [AgentPermissionMode]? { cycle }
        func operatePanel(_ input: SlashPanel.Input) async -> Bool {
            operated.append(input)
            return true
        }
        func clearPanel() { panel = nil }
        func sendPanelCommand(_ text: String) async -> Bool {
            commands.append(text)
            return commandSucceeds
        }
        func cancelPanelWatch() { isWatchingPanel = false }
        func setNotice(_ notice: SendNotice?) { notices.append(notice) }
        func refreshModelCatalog() {}
        func readScreenPermissionMode(verifying: Bool) async -> AgentPermissionMode? {
            screenModes.isEmpty ? nil : screenModes.removeFirst()
        }
        func recordSwitchedScreenMode(_ mode: AgentPermissionMode) { recorded.append(mode) }
        func recordProbedScreenMode(_ mode: AgentPermissionMode) { recorded.append(mode) }
        func sendShiftTab() async throws { keysSent.append("shift+tab") }
        func pause(_ duration: Duration) async throws {}
        func play(_ feedback: HapticFeedback) { feedbacks.append(feedback) }
    }

    private static func claudeControls(link: AgentControls.Link = .init()) -> AgentControls {
        AgentControls(
            dialect: AgentCatalog.profile(forHerdrName: "claude").screen, metadata: TranscriptMetadata(permissionMode: "default"),
            link: link)
    }

    private static func make(_ host: FakeHost) -> AgentControlSwitcher {
        let switcher = AgentControlSwitcher()
        switcher.host = host
        return switcher
    }

    @Test("權限模式:按到畫面顯示目標為止(切換 2 次)")
    func reachesTarget() async {
        let host = FakeHost(controls: Self.claudeControls())
        host.screenModes = [.normal, .acceptEdits, .plan]
        let switcher = Self.make(host)
        await switcher.setPermissionMode(.plan)
        #expect(host.keysSent == ["shift+tab", "shift+tab"])
        #expect(switcher.permissionModeFailure == nil)
        #expect(switcher.switchingPermissionMode == nil)
        #expect(host.feedbacks == [.selection])
    }

    @Test("權限模式:停用原因(離線、等你回覆、唯讀)一個鍵都不送")
    func locksSendNoKeys() async {
        for link in [AgentControls.Link(isOffline: true), AgentControls.Link(agentStatus: .blocked)] {
            let host = FakeHost(controls: Self.claudeControls(link: link))
            host.screenModes = [.normal]
            await Self.make(host).setPermissionMode(.plan)
            #expect(host.keysSent.isEmpty)
        }
        let readOnly = FakeHost(controls: Self.claudeControls(link: .init(isReadOnly: true)))
        readOnly.isReadOnly = true
        await Self.make(readOnly).setPermissionMode(.plan)
        #expect(readOnly.keysSent.isEmpty)
        #expect(readOnly.notices.last == .readOnlyDevice)
    }

    @Test("權限模式:讀不到畫面記成 unreadable,不送鍵")
    func unreadable() async {
        let host = FakeHost(controls: Self.claudeControls())
        let switcher = Self.make(host)
        await switcher.setPermissionMode(.plan)
        #expect(switcher.permissionModeFailure == .unreadable(target: .plan))
        #expect(host.keysSent.isEmpty)
    }

    @Test("模型:選定時移動游標再按 s(不是 Enter),不送數字")
    func chooseModelPressesS() async {
        let host = FakeHost(controls: Self.claudeControls())
        let option = SlashPanelOption(index: 1, label: "Sonnet")
        let confirmS = SlashPanelAction(key: "s", label: "this session")
        let confirmEnter = SlashPanelAction(key: "enter", label: "default")
        host.panel = SlashPanel(title: "Model", options: [option], actions: [confirmEnter, confirmS])
        let switcher = Self.make(host)
        await switcher.beginChoosingModel()
        #expect(host.commands == ["/model"])
        #expect(switcher.isChoosingModel)
        await switcher.chooseModel(option)
        #expect(host.operated == [.select(option), .action(confirmS)])
        #expect(!switcher.isChoosingModel)
        #expect(!switcher.isSwitchingModel)
    }

    @Test("模型:送不出 /model 時 sheet 關掉")
    func commandFailureClosesSheet() async {
        let host = FakeHost(controls: Self.claudeControls())
        host.commandSucceeds = false
        let switcher = Self.make(host)
        await switcher.beginChoosingModel()
        #expect(!switcher.isChoosingModel)
    }

    @Test("模型:不能選(canChooseModel 為 false)時什麼都不送")
    func guardedByHost() async {
        let host = FakeHost(controls: Self.claudeControls())
        host.canChooseModel = false
        let switcher = Self.make(host)
        await switcher.beginChoosingModel()
        #expect(host.commands.isEmpty)
        #expect(!switcher.isChoosingModel)
    }
}
