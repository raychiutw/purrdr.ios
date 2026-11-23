import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 模型選擇 sheet 的目錄來源(#385):開 sheet 才問目錄、讀到就換上;面板的列與目前模型對到目錄項目,徽章取自目錄。
/// **不對任何真實 agent 送 slash 指令或按鍵。**
@MainActor
@Suite("模型選擇 sheet:模型目錄")
struct ConversationModelCatalogTests {
    struct StubCatalog: ModelCatalogProviding {
        var resolved: ResolvedModelCatalog
        func catalog() async -> ResolvedModelCatalog { resolved }
    }

    static let fromHost = ResolvedModelCatalog(
        catalog: ModelCatalogParser.parse(Fixtures.modelCatalog("host-cache-cc.json")) ?? .builtIn, source: .hostCache)

    static func panelOpen(provider: (any ModelCatalogProviding)?) async throws -> ConversationAnswerTests.Setup {
        let setup = try ConversationAnswerTests.setup(sleeper: RecordingSleeper { $0 == .milliseconds(300) }, modelCatalog: provider)
        await setup.host.bridge.expect(ConversationModelChoiceTests.bridge, reply: ConversationAnswerTests.snapshot(status: "idle", kind: "claude"))
        await setup.model.poll()
        await ConversationSlashPanelTests.expectSlashSend(setup)
        await setup.model.beginChoosingModel()
        await setup.host.bridge.expect(ConversationModelChoiceTests.bridge, reply: ConversationSlashPanelTests.idle())
        await setup.host.bridge.expect(ConversationModelChoiceTests.bridge, reply: PaneScreens.read("claude-panel-model"))
        await setup.model.poll()
        return setup
    }

    static func waitForCatalog(_ model: ConversationModel, source: ModelCatalogSource) async {
        let deadline = ContinuousClock.now + asyncWaitLimit
        while model.modelCatalog.source != source, ContinuousClock.now < deadline { await Task.yield() }
    }

    @Test("沒有目錄提供者(或還沒讀到):用內建對照表,sheet 仍可用、不顯示倍率徽章")
    func startsWithBuiltIn() async throws {
        let setup = try await Self.panelOpen(provider: nil)
        #expect(setup.model.modelCatalog.source == .builtIn)
        #expect(setup.model.isChoosingModel)
        #expect(setup.model.effortOption("max")?.badge == nil)
    }

    @Test("開 sheet 時問目錄,讀到主機快取就換上;面板的列對到目錄項目")
    func loadsCatalogWhenSheetOpens() async throws {
        let setup = try await Self.panelOpen(provider: StubCatalog(resolved: Self.fromHost))
        await Self.waitForCatalog(setup.model, source: .hostCache)

        #expect(setup.model.modelCatalog.source == .hostCache)
        let panel = try #require(setup.model.panel)
        let opus = try #require(panel.options.first { $0.isCurrent })
        #expect(setup.model.catalogEntry(for: opus)?.id == "claude-opus-5-5")
        // 目前模型的 effort 徽章取自目錄:Medium 推薦、Max 的使用量倍率警示。
        #expect(setup.model.effortOption("medium")?.badge?.message == "Recommended")
        #expect(setup.model.effortOption("max")?.badge == ModelBadge(message: "3.5× or more usage", variant: .warning))
        #expect(setup.model.effortOption("low")?.badge == nil)
    }

    @Test("面板列對不到目錄:沒有項目(畫面維持面板自己的描述、不顯示徽章)")
    func unmatchedOptionHasNoEntry() async throws {
        let setup = try await Self.panelOpen(provider: StubCatalog(resolved: Self.fromHost))
        await Self.waitForCatalog(setup.model, source: .hostCache)
        #expect(setup.model.catalogEntry(for: SlashPanelOption(index: 9, label: "Default (recommended)")) == nil)
    }

    @Test("目錄來源失敗退到內建:目前模型沒有倍率徽章")
    func builtInHasNoMultiplierBadge() async throws {
        let builtIn = ResolvedModelCatalog(catalog: .builtIn, source: .builtIn)
        let setup = try await Self.panelOpen(provider: StubCatalog(resolved: builtIn))
        #expect(setup.model.effortOption("max")?.badge == nil)
        #expect(setup.model.currentModelEntry?.supportsXHigh == true)
    }
}
