import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import Testing

/// HTTPS 主機的新增聊天與 workspace／worktree 操作(#287):經假主機服務 WebSocket,從 `HerdrClient` 這一端驗證。
@Suite("HTTPS 主機的結構操作")
struct HTTPSStructureOperationsTests {
    /// 有結構操作的主機服務版本。
    private static let currentVersion = "0.7.0"

    private static func client(to service: FakeHostService) -> HerdrClient {
        HerdrClient(connection: HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9"))
    }

    private static func start(_ settings: FakeHostService.Settings = .init(hostServiceVersion: currentVersion)) async throws -> FakeHostService {
        try await FakeHostService.start(settings)
    }

    private static func sent(_ service: FakeHostService, type: String) throws -> [String: Any] {
        let messages = service.log.messages.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return try #require(messages.last { $0["type"] as? String == type })
    }

    @Test("建立 workspace 送 workspace.create(cwd、label),回傳新 workspace 與 root pane")
    func createWorkspace() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let created = try await Self.client(to: service).createWorkspace(cwd: "/Users/demo/Projects/garden-journal", label: "garden-journal")

        let sent = try Self.sent(service, type: "workspace.create")
        #expect(sent["cwd"] as? String == "/Users/demo/Projects/garden-journal")
        #expect(sent["label"] as? String == "garden-journal")
        #expect(created == CreatedWorkspace(workspaceID: "w1", rootPaneID: "w1:p1"))
    }

    @Test("主機服務說資料夾不存在：錯誤是 folder_not_found,不是看不懂的回應")
    func createWorkspaceInMissingFolder() async throws {
        let service = try await Self.start(.init(hostServiceVersion: Self.currentVersion, missingFolders: ["/Users/demo/gone"]))
        defer { Task { await service.stop() } }

        await #expect {
            _ = try await Self.client(to: service).createWorkspace(cwd: "/Users/demo/gone", label: nil)
        } throws: { error in
            if case HerdrError.herdr(code: "folder_not_found", _) = error { return true }
            return false
        }
    }

    @Test("重新命名送 workspace.rename")
    func renameWorkspace() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        try await Self.client(to: service).renameWorkspace("w1", to: "garden-notes")

        let sent = try Self.sent(service, type: "workspace.rename")
        #expect(sent["workspace_id"] as? String == "w1")
        #expect(sent["label"] as? String == "garden-notes")
    }

    @Test("重新命名 Tab 送 tab.rename {tab_id, label}(#458)")
    func renameTab() async throws {
        let service = try await Self.start(.init(hostServiceVersion: "0.13.1"))
        defer { Task { await service.stop() } }

        try await Self.client(to: service).renameTab("w1:t1", to: "build-logs")

        let sent = try Self.sent(service, type: "tab.rename")
        #expect(sent["tab_id"] as? String == "w1:t1")
        #expect(sent["label"] as? String == "build-logs")
    }

    @Test("重新命名 Tab:主機服務 0.13.0 之前不送出，回「需要更新主機服務」(#458)")
    func renameTabOnOlderHostService() async throws {
        let service = try await Self.start(.init(hostServiceVersion: "0.13.0"))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.tabRename, installedVersion: "0.13.0")) {
            try await Self.client(to: service).renameTab("w1:t1", to: "build-logs")
        }
        #expect(!service.log.messages.contains { $0.contains("tab.rename") })
    }

    @Test("重新命名 Tab:唯讀裝置被拒，錯誤種類是 readOnlyDevice(#458)")
    func renameTabOnReadOnlyDevice() async throws {
        let service = try await Self.start(.init(readOnlyTokens: ["token-ok"], hostServiceVersion: "0.13.1"))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.readOnlyDevice) {
            try await Self.client(to: service).renameTab("w1:t1", to: "build-logs")
        }
    }

    @Test("重新命名 Tab:herdr 的錯誤碼 tab_not_found 原樣透傳(#458)")
    func renameMissingTab() async throws {
        let service = try await Self.start(.init(hostServiceVersion: "0.13.1", structureHerdrErrors: ["tab.rename": "tab_not_found"]))
        defer { Task { await service.stop() } }

        await #expect {
            try await Self.client(to: service).renameTab("w1:t9", to: "x")
        } throws: { error in
            if case HerdrError.herdr(code: "tab_not_found", _) = error { return true }
            return false
        }
    }

    @Test("關閉送 workspace.close")
    func closeWorkspace() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        try await Self.client(to: service).closeWorkspace("w2")

        #expect(try Self.sent(service, type: "workspace.close")["workspace_id"] as? String == "w2")
    }

    @Test("herdr 拒絕關閉(worktree 群組還開著):herdr 的碼原樣回報")
    func closeWorkspaceGroupRequired() async throws {
        let service = try await Self.start(.init(
            hostServiceVersion: Self.currentVersion, structureHerdrErrors: ["workspace.close": "workspace_group_close_required"]))
        defer { Task { await service.stop() } }

        await #expect {
            try await Self.client(to: service).closeWorkspace("w1")
        } throws: { error in
            if case HerdrError.herdr(code: "workspace_group_close_required", _) = error { return true }
            return false
        }
    }

    @Test("建立 worktree 送 worktree.create,回傳新 workspace 與 root pane")
    func createWorktree() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let created = try await Self.client(to: service).createWorktree(from: "w1", branch: "feature/sketch")

        let sent = try Self.sent(service, type: "worktree.create")
        #expect(sent["workspace_id"] as? String == "w1")
        #expect(sent["branch"] as? String == "feature/sketch")
        #expect(created == CreatedWorkspace(workspaceID: "w3", rootPaneID: "w3:p1"))
    }

    @Test("啟動 Agent 送 agent.start;Claude Code 的權限模式換成 permission_mode")
    func startAgentWithPermissionMode() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        try await Self.client(to: service).startAgent(
            name: "feature-sketch", kind: "claude", paneID: "w3:p1", arguments: ["--permission-mode", "acceptEdits"], timeout: .seconds(60))

        let sent = try Self.sent(service, type: "agent.start")
        #expect(sent["pane_id"] as? String == "w3:p1")
        #expect(sent["name"] as? String == "feature-sketch")
        #expect(sent["kind"] as? String == "claude")
        #expect(sent["permission_mode"] as? String == "acceptEdits")
        #expect(sent["timeout_ms"] as? Int == 60000)
    }

    @Test("沒選權限模式：agent.start 不帶 permission_mode")
    func startAgentWithoutArguments() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        try await Self.client(to: service).startAgent(name: "ledger", kind: "codex", paneID: "w1:p1", arguments: [], timeout: .seconds(60))

        #expect(try Self.sent(service, type: "agent.start")["permission_mode"] == nil)
    }

    /// #400:Codex 新聊天帶 `--no-daemon`;主機服務不收參數,不能因此讓 HTTPS 主機開不了 Codex。
    @Test("Codex 的 --no-daemon:HTTPS 略過它照常啟動,不當成不支援")
    func startCodexIgnoresNoDaemon() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        try await Self.client(to: service).startAgent(name: "ledger", kind: "codex", paneID: "w1:p1", arguments: ["--no-daemon"], timeout: .seconds(60))

        let sent = try Self.sent(service, type: "agent.start")
        #expect(sent["kind"] as? String == "codex")
        #expect(sent["permission_mode"] == nil)
    }

    @Test("協定不接受的 Agent 參數：不送出，錯誤種類是 unsupported")
    func startAgentWithArbitraryArguments() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.unsupported("agent.start")) {
            try await Self.client(to: service).startAgent(
                name: "ledger", kind: "claude", paneID: "w1:p1", arguments: ["--dangerously-skip-permissions"], timeout: .seconds(60))
        }
        #expect(!service.log.messages.contains { $0.contains("agent.start") })
    }

    @Test("主機服務版本不足：不送出，回「需要更新主機服務」的專屬錯誤")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await Self.start(.init(hostServiceVersion: "0.6.0"))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.workspaceOperations, installedVersion: "0.6.0")) {
            try await Self.client(to: service).renameWorkspace("w1", to: "garden-notes")
        }
        #expect(!service.log.messages.contains { $0.contains("workspace.rename") })
    }

    @Test("唯讀裝置：主機服務拒絕，錯誤種類是 readOnlyDevice")
    func readOnlyDevice() async throws {
        let service = try await Self.start(.init(readOnlyTokens: ["token-ok"], hostServiceVersion: Self.currentVersion))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.readOnlyDevice) {
            _ = try await Self.client(to: service).createWorktree(from: "w1", branch: "feature/sketch")
        }
    }

    @Test(
        "結構操作都是寫入類(schema 的 x-write)",
        arguments: [
            #"{"id":"1","method":"workspace.create","params":{"cwd":"/tmp","focus":false}}"#,
            #"{"id":"1","method":"workspace.rename","params":{"workspace_id":"w1","label":"a"}}"#,
            #"{"id":"1","method":"tab.rename","params":{"tab_id":"w1:t1","label":"a"}}"#,
            #"{"id":"1","method":"workspace.close","params":{"workspace_id":"w1"}}"#,
            #"{"id":"1","method":"worktree.create","params":{"workspace_id":"w1","branch":"b"}}"#,
            #"{"id":"1","method":"agent.start","params":{"name":"a","kind":"claude","pane_id":"w1:p1","timeout_ms":1000}}"#,
        ])
    func structureOperationsAreWrites(request: String) throws {
        #expect(try HTTPSHostConnection.isWriteRequest(Data(request.utf8)))
    }

    // MARK: - 新增聊天

    @Test("新增聊天：絕對路徑直接用，依序建立 workspace、啟動 Agent、送第一則訊息")
    func newChatOverHostService() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let client = Self.client(to: service)
        let launcher = NewChatLauncher(client: client, folders: .absolutePathsOnly)

        let started = try await launcher.start(NewChatRequest(
            folder: "/Users/demo/Projects/garden-journal", agent: .claude, message: "整理照片標籤"))

        let types = service.log.messages.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .compactMap { $0["type"] as? String }
        #expect(types.filter { $0 != "hello" } == ["workspace.create", "agent.start", "agent.prompt"])
        #expect(try Self.sent(service, type: "agent.start")["name"] as? String == "garden-journal")
        #expect(try Self.sent(service, type: "agent.prompt")["pane_id"] as? String == "w1:p1")
        #expect(started == NewChatStarted(workspace: CreatedWorkspace(workspaceID: "w1", rootPaneID: "w1:p1"), sentMessage: true))
    }

    @Test("沒有資料夾瀏覽的主機：`~` 開頭的路徑要求改成絕對路徑，不送出")
    func newChatNeedsAbsolutePath() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let launcher = NewChatLauncher(client: Self.client(to: service), folders: .absolutePathsOnly)

        await #expect(throws: NewChatFolderError.absolutePathRequired("~/Projects")) {
            _ = try await launcher.start(NewChatRequest(folder: "~/Projects", agent: .claude, message: "hi"))
        }
        #expect(!service.log.messages.contains { $0.contains("workspace.create") })
    }

    @Test("沒有資料夾瀏覽的主機：不能瀏覽，列出資料夾是 unsupported")
    func absolutePathsOnlyCannotBrowse() async throws {
        let folders = NewChatFolders.absolutePathsOnly

        #expect(!folders.canBrowse)
        #expect(NewChatFolders(channel: FakeNoChannel()).canBrowse)
        await #expect(throws: HostServiceError.unsupported("folders")) {
            _ = try await folders.list(nil)
        }
    }
}

/// 只用來建 `NewChatFolders` 的通道(不會被呼叫)。
private struct FakeNoChannel: HostChannel {
    func execute(_ command: String) async throws -> any ExecSession { throw HostServiceError.unsupported("ssh") }
    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { throw HostServiceError.unsupported("ssh") }
}
