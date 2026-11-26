import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// Agent 控制(#561):三個來源的優先序與停用規則,直接用值測,不搭主機替身。
@Suite("Agent 控制")
struct AgentControlsTests {
    private static func dialect(_ herdrName: String) -> ScreenDialect { AgentCatalog.profile(forHerdrName: herdrName).screen }

    private static let claude = dialect("claude")
    private static let codex = dialect("codex")
    private static let antigravity = dialect("agy")

    private static func statusFile(model: String? = nil, effort: String? = nil, cycle: String? = nil) -> ClaudeSessionStatus {
        ClaudeSessionStatus(sessionID: "s", model: model, effort: effort, cycleMode: cycle)
    }

    // MARK: 模型與 effort 的優先序

    @Test("模型與 effort:status line 檔 > 畫面狀態列 > 對話紀錄(只有狀態列方言認前兩者)")
    func modelPriority() {
        let metadata = TranscriptMetadata(model: "claude-opus-4-7", effort: "high")
        var observations = AgentControlObservations()
        observations.observeStatusLine(AgentStatusLine(mode: nil, model: "Screen Model", effort: "low"))
        let file = Self.statusFile(model: "File Model (Medium)", effort: "max", cycle: "plan")

        // 狀態列方言:檔案 > 畫面 > 紀錄
        let agy = AgentControls(dialect: Self.antigravity, metadata: metadata, sessionStatus: file, observations: observations)
        #expect(agy.modelName == "File Model")
        #expect(agy.effortLevel == "max")
        let agyNoFile = AgentControls(dialect: Self.antigravity, metadata: metadata, observations: observations)
        #expect(agyNoFile.modelName == "Screen Model")
        #expect(agyNoFile.effortLevel == "low")
        let agyBare = AgentControls(dialect: Self.antigravity, metadata: metadata)
        #expect(agyBare.modelName == TranscriptMetadata.displayName(ofModel: "claude-opus-4-7"))
        #expect(agyBare.effortLevel == "high")

        // 沒有狀態列的方言:檔案與畫面狀態列都不認,只看對話紀錄
        let cc = AgentControls(dialect: Self.claude, metadata: metadata, sessionStatus: file)
        #expect(cc.modelName == TranscriptMetadata.displayName(ofModel: "claude-opus-4-7"))
        #expect(cc.effortLevel == "high")
    }

    @Test("膠囊摘要:有 effort 加在後面,都沒有是 nil")
    func summary() {
        let both = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(model: "claude-opus-4-7", effort: "medium"))
        #expect(both.modelSummary?.hasSuffix(" · \(String(localized: "Medium"))") == true)
        let modelOnly = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(model: "claude-opus-4-7"))
        #expect(modelOnly.modelSummary == modelOnly.modelName)
        #expect(AgentControls(dialect: Self.claude, metadata: TranscriptMetadata()).modelSummary == nil)
    }

    // MARK: 權限模式的優先序

    @Test("狀態列方言的權限模式:檔案 > 畫面狀態列;對話紀錄不算")
    func statusLineModePriority() {
        var observations = AgentControlObservations()
        observations.observeStatusLine(AgentStatusLine(mode: .acceptEdits, model: nil, effort: nil))
        let metadata = TranscriptMetadata(permissionMode: "plan")
        let file = Self.statusFile(cycle: "auto")
        #expect(AgentControls(dialect: Self.antigravity, metadata: metadata, sessionStatus: file, observations: observations).permissionMode == .auto)
        #expect(AgentControls(dialect: Self.antigravity, metadata: metadata, observations: observations).permissionMode == .acceptEdits)
        // 狀態列沒讀到模式(default 模式):退回紀錄
        let blank = AgentControls(dialect: Self.antigravity, metadata: TranscriptMetadata())
        #expect(blank.permissionMode == nil)
    }

    @Test("Claude 的權限模式:紀錄為準,畫面只補紀錄還沒寫入的空檔")
    func claudeModePriority() {
        // 紀錄是 plan,畫面當時也是在紀錄為 plan 時認到 acceptEdits:紀錄沒變 → 畫面補空檔
        var observations = AgentControlObservations()
        observations.observeScreen(mode: .acceptEdits, transcriptValue: "plan")
        let same = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(permissionMode: "plan"), observations: observations)
        #expect(same.permissionMode == .acceptEdits)
        // 紀錄更新(auto):以紀錄為準
        let updated = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(permissionMode: "auto"), observations: observations)
        #expect(updated.permissionMode == .auto)
        // 紀錄還沒有:用畫面
        var screenOnly = AgentControlObservations()
        screenOnly.observeScreen(mode: .plan, transcriptValue: nil)
        #expect(AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(), observations: screenOnly).permissionMode == .plan)
        // 都沒有
        #expect(AgentControls(dialect: Self.claude, metadata: TranscriptMetadata()).permissionMode == nil)
    }

    // MARK: 可選項

    @Test("輪替選項:預設三種,看過略過權限或自動才加入;目前是 dontAsk 多一列")
    func options() {
        let base = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(permissionMode: "default"))
        #expect(base.permissionModeOptions == [.normal, .acceptEdits, .plan])

        var seen = AgentControlObservations()
        seen.noteTranscript(lines: [#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#])
        let withBypass = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(permissionMode: "default"), observations: seen)
        #expect(withBypass.permissionModeOptions == [.normal, .acceptEdits, .plan, .bypassPermissions])

        let dontAsk = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(permissionMode: "dontAsk"))
        #expect(dontAsk.permissionModeOptions.last == .dontAsk)

        // 有自己輪替的 Agent:固定是輪替裡的幾種
        let agy = AgentControls(dialect: Self.antigravity, metadata: TranscriptMetadata())
        #expect(agy.permissionModeOptions == [.normal, .acceptEdits, .plan, .auto])
    }

    // MARK: 停用原因(一套)

    @Test("停用原因表:唯讀 > 離線 > 等你回覆 > 工作中(只有閒置才能切換的 Agent)")
    func lockTable() {
        typealias Link = AgentControls.Link
        let rows: [(ScreenDialect, Link, AgentControls.PermissionModeLock?)] = [
            (Self.claude, Link(), nil),
            (Self.claude, Link(agentStatus: .working), nil),
            (Self.claude, Link(agentStatus: .blocked), .waitingForYou),
            (Self.claude, Link(isReadOnly: true, isOffline: true, agentStatus: .blocked), .readOnlyDevice),
            (Self.claude, Link(isOffline: true, agentStatus: .blocked), .offline),
            (Self.antigravity, Link(agentStatus: .working), .working),
            (Self.antigravity, Link(agentStatus: .blocked), .waitingForYou),
            (Self.antigravity, Link(agentStatus: .done), nil),
        ]
        for (dialect, link, expected) in rows {
            let controls = AgentControls(dialect: dialect, metadata: TranscriptMetadata(), link: link)
            #expect(controls.permissionModeLock == expected, "\(dialect.name) \(link)")
        }
    }

    @Test("能不能切換:支援、讀到目前模式、沒在切換、沒有停用原因")
    func canSwitch() {
        let metadata = TranscriptMetadata(permissionMode: "default")
        let ok = AgentControls(dialect: Self.claude, metadata: metadata)
        #expect(ok.canSwitchPermissionMode(isSwitching: false))
        #expect(!ok.canSwitchPermissionMode(isSwitching: true))
        #expect(!AgentControls(dialect: Self.claude, metadata: TranscriptMetadata()).canSwitchPermissionMode(isSwitching: false))
        #expect(!AgentControls(dialect: Self.claude, metadata: metadata, link: .init(isReadOnly: true)).canSwitchPermissionMode(isSwitching: false))
        // Codex 沒有權限模式切換
        #expect(!AgentControls(dialect: Self.codex, metadata: metadata).canSwitchPermissionMode(isSwitching: false))
    }

    // MARK: 顯示

    @Test("膠囊顯示與標題列:Claude 一律顯示,Codex 要讀到模型,標題列只有可切換或有狀態列的 Agent 帶模式")
    func displays() {
        let claudeBare = AgentControls(dialect: Self.claude, metadata: TranscriptMetadata())
        #expect(claudeBare.showsModelCapsule)
        let codexBare = AgentControls(dialect: Self.codex, metadata: TranscriptMetadata())
        #expect(!codexBare.showsModelCapsule)
        let codexModel = AgentControls(dialect: Self.codex, metadata: TranscriptMetadata(model: "gpt-5.5", approvalPolicy: "on-request"))
        #expect(codexModel.showsModelCapsule)
        #expect(codexModel.approvalPolicy == "on-request")
        #expect(claudeBare.approvalPolicy == nil)
    }

    @Test("能開模型選擇:Claude 閒置才行,唯讀、離線、工作中、有提問、面板、送出中、選擇中都不行,Codex 不行")
    func canChooseModel() {
        func claude(_ link: AgentControls.Link = .init(agentStatus: .idle)) -> AgentControls {
            AgentControls(dialect: Self.claude, metadata: TranscriptMetadata(), link: link)
        }
        let open = AgentControls.ChooseModelInputs()
        #expect(claude().canChooseModel(open))
        #expect(!claude(.init(isReadOnly: true, agentStatus: .idle)).canChooseModel(open))
        #expect(!claude(.init(isOffline: true, agentStatus: .idle)).canChooseModel(open))
        #expect(!claude(.init(hasPrompt: true, agentStatus: .idle)).canChooseModel(open))
        #expect(!claude(.init(agentStatus: .working)).canChooseModel(open))
        #expect(!claude(.init(agentStatus: .blocked)).canChooseModel(open))
        #expect(!claude().canChooseModel(.init(hasTarget: false)))
        #expect(!claude().canChooseModel(.init(isSending: true)))
        #expect(!claude().canChooseModel(.init(hasTypedAnswer: true)))
        #expect(!claude().canChooseModel(.init(hasPanel: true)))
        #expect(!claude().canChooseModel(.init(isChoosingModel: true)))
        let codex = AgentControls(dialect: Self.codex, metadata: TranscriptMetadata(), link: .init(agentStatus: .idle))
        #expect(!codex.canChooseModel(open))
    }
}
