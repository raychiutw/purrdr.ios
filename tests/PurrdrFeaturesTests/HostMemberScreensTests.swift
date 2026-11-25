#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 一台主機的畫面 model 工廠(#563、#564,`HostMember+Screens`):只用假能力組與假環境單獨測,不經 `HostsModel`、不看連線方式。
@MainActor
@Suite("主機成員的畫面 model 工廠")
struct HostMemberScreensTests {
    static let host = HostAdaptersTests.sshHost

    /// 以假能力組建立成員;`environment` 的名稱、啟用 Agent、已存主機判斷都由測試指定。
    static func member(
        savedHost: Bool = true, enabled: Set<AgentID> = [.claude, .codex], supportsExistingWorkspaces: Bool = true
    ) -> HostMember {
        let adapter = HostAdaptersTests().environment()
        let capabilities = SSHHostAdapter(environment: adapter).capabilities(for: host)
        var environment = HostMemberEnvironment.inert
        environment.hostName = { _ in "Studio Mac" }
        environment.enabledAgents = { _ in enabled }
        environment.isSavedHost = { _ in savedHost }
        environment.supportsNewChatInWorkspace = { _ in supportsExistingWorkspaces }
        return HostMember(
            host: .host(host.id), hostID: host.id.uuidString, capabilities: capabilities,
            preferences: InMemoryChatPreferencesStore(), push: nil, environment: environment)
    }

    @Test("對話 model:綁定這個 pane,標題列主機名取自環境(聊天所在主機)")
    func conversationUsesRouteAndHostName() {
        let member = Self.member()
        let model = member.conversation(ChatRoute(host: .host(Self.host.id), paneID: "w1:p1"), sessionID: "s-1")
        #expect(model.paneID == "w1:p1")
        #expect(model.header.segments.contains("Studio Mac"), "\(model.header.segments)")
    }

    @Test("對話 model:草稿存在這台主機的成員上,新增聊天留下的草稿開聊天時就在輸入框")
    func conversationRestoresDraftKeptByNewChat() {
        let member = Self.member()
        member.keepDraft("先看一下 README", paneID: "w9:p1")
        let model = member.conversation(ChatRoute(host: .host(Self.host.id), paneID: "w9:p1"), sessionID: nil)
        #expect(model.draft == "先看一下 README")
        let other = member.conversation(ChatRoute(host: .host(Self.host.id), paneID: "w2:p1"), sessionID: nil)
        #expect(other.draft.isEmpty, "別的 pane 沒有草稿")
    }

    @Test("對話快取:key 帶主機身分,兩台主機相同的 pane 不會互相覆蓋")
    func conversationCacheIsHostScoped() async {
        let member = Self.member()
        let cached = CachedConversation(
            sessionID: "s-1", messages: [], metadata: TranscriptMetadata(), path: "/t.jsonl", cursor: 0, windowStart: 0)
        await member.conversationCache.save(cached, chatKey: "w1:p1")
        let base = member.environment.conversationCache
        #expect(await base.load(chatKey: "w1:p1") == nil, "沒有主機身分的 key 讀不到")
        #expect(await member.conversationCache.load(chatKey: "w1:p1") != nil)
    }

    @Test("新增聊天:Agent 選項只列這台主機啟用的")
    func newChatListsEnabledAgentsOnly() {
        let both = Self.member(enabled: [.claude, .codex]).newChat()
        #expect(Set(both.availableAgents) == [.claude, .codex])
        let claudeOnly = Self.member(enabled: [.claude]).newChat()
        #expect(claudeOnly.availableAgents == [.claude])
        #expect(Self.member(enabled: []).newChat().availableAgents.isEmpty)
    }

    @Test("新增聊天:這台主機不能在既有 Workspace 新增時,不讀 Workspace 清單、也不提供選擇")
    func newChatWithoutExistingWorkspaceSupport() async {
        let model = Self.member(supportsExistingWorkspaces: false).newChat()
        await model.loadWorkspaces()
        #expect(!model.canChooseExistingWorkspace)
        #expect(model.workspaces.isEmpty)
    }

    @Test("Pane 終端機、登入 Shell、檔案瀏覽:標題與主機名來自成員與環境")
    func terminalShellAndFolders() {
        let member = Self.member()
        #expect(member.terminal(paneID: "w1:p1", title: "ledger").title == "ledger")
        #expect(member.loginShell().title == "Studio Mac")
        #expect(member.folderBrowser().hostName == "Studio Mac")
    }

    @Test("用量區:只列這台主機啟用的 Agent")
    func usageSectionFiltersDisabledAgents() {
        let claudeOnly = Self.member(enabled: [.claude]).usageSection(agents: [.claudeCode, .codex])
        #expect(claudeOnly.agents == [.claudeCode])
        let both = Self.member(enabled: [.claude, .codex]).usageSection(agents: [.claudeCode, .codex])
        #expect(both.agents == [.claudeCode, .codex])
        #expect(Self.member(enabled: []).usageSection(agents: [.claudeCode, .codex]).agents.isEmpty)
    }

    @Test("主機設定與 Agent 設定:只給已存主機;範例主機(不是已存主機)是 nil")
    func settingsOnlyForSavedHosts() {
        let unsaved = Self.member(savedHost: false)
        #expect(unsaved.settings() == nil)
        #expect(unsaved.agentSettings() == nil)
        let saved = Self.member(savedHost: true, enabled: [.claude])
        #expect(saved.agentSettings()?.enabled == [.claude])
        #expect(saved.settings() != nil)
    }

    @Test("主機設定:Codex 啟動器每台主機只建一次(畫面每次重繪都會呼叫)")
    func settingsReusesCodexLauncher() throws {
        let member = Self.member()
        let first = try #require(member.settings())
        let second = try #require(member.settings())
        #expect(first == second)
    }
}
#endif
