#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import Testing

/// 主機頁「Agent」子頁的 model(#477):逐一開關、偵測狀態、列表副標。
@MainActor
@Suite("主機的 Agent 設定頁")
struct HostAgentSettingsModelTests {
    final class Saved {
        var values: [Set<AgentID>] = []
    }

    func model(enabled: Set<AgentID>, detected: Result<Set<AgentID>, any Error>, saved: Saved = Saved()) -> HostAgentSettingsModel {
        HostAgentSettingsModel(
            enabled: enabled,
            detect: { try detected.get() },
            save: { saved.values.append($0) })
    }

    @Test("每個可設定的 Agent 一列,名稱取自 Agent 設定檔;偵測前沒有偵測結果")
    func rowsBeforeDetection() {
        let model = model(enabled: [.claude], detected: .success([]))
        #expect(model.rows.map(\.agent) == HostAgentSettings.configurable)
        #expect(model.rows.first?.name == "Claude Code")
        #expect(model.rows.map(\.detection).allSatisfy { $0 == .checking })
        #expect(model.rows.filter(\.isEnabled).map(\.agent) == [.claude])
    }

    @Test("偵測後每列標示已偵測到或沒有偵測到;沒偵測到的也可以手動打開")
    func detectionAndManualEnable() async {
        let saved = Saved()
        let model = model(enabled: [], detected: .success([.claude, .agy]), saved: saved)
        await model.load()
        #expect(model.row(for: .claude)?.detection == .detected)
        #expect(model.row(for: .codex)?.detection == .notDetected)
        model.setEnabled(.codex, true)
        #expect(model.row(for: .codex)?.isEnabled == true)
        #expect(saved.values == [[.codex]])
    }

    @Test("關掉一個只改那一個,每次改變都存起來")
    func togglesOneAtATime() {
        let saved = Saved()
        let model = model(enabled: [.claude, .codex], detected: .success([]), saved: saved)
        model.setEnabled(.codex, false)
        model.setEnabled(.claude, false)
        #expect(saved.values == [[.claude], []])
        #expect(model.rows.allSatisfy { !$0.isEnabled })
    }

    @Test("沒改變就不存")
    func unchangedDoesNotSave() {
        let saved = Saved()
        let model = model(enabled: [.claude], detected: .success([]), saved: saved)
        model.setEnabled(.claude, true)
        model.setEnabled(.codex, false)
        #expect(saved.values.isEmpty)
    }

    @Test("偵測失敗(主機離線):不標示偵測結果,不影響開關")
    func detectionFailure() async {
        let model = model(enabled: [.claude], detected: .failure(CancellationError()))
        await model.load()
        #expect(model.rows.map(\.detection).allSatisfy { $0 == .unknown })
        #expect(model.row(for: .claude)?.isEnabled == true)
    }

    @Test("列表副標:列出啟用的 Agent 名稱,全關是空字串")
    func summary() {
        #expect(model(enabled: [.claude, .agy], detected: .success([])).enabledNames == ["Claude Code", "Antigravity"])
        #expect(model(enabled: [], detected: .success([])).enabledNames.isEmpty)
        #expect(HostAgentSettingsModel.enabledNames(of: [.agy, .claude]) == ["Claude Code", "Antigravity"], "主機頁的列共用同一個來源")
    }
}
#endif
