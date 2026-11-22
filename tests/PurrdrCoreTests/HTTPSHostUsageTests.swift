import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// 主機服務 0.12.0 的方案用量、session context、用量擷取與資料夾瀏覽(#416):經假主機服務 WebSocket 驗證。
@Suite("HTTPS 主機的用量與資料夾瀏覽")
struct HTTPSHostUsageTests {
    private static func start(
        _ replies: [String: [String]] = [:], version: String = "0.12.0", readOnly: Bool = false, home: String? = nil
    ) async throws -> FakeHostService {
        var settings = FakeHostService.Settings(hostServiceVersion: version)
        settings.usageReplies = replies
        settings.homeDirectory = home
        if readOnly { settings.readOnlyTokens = ["token-ok"] }
        return try await FakeHostService.start(settings)
    }

    private static func connection(_ service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    private static func errorReply(_ code: String, _ message: String = "failed") -> String {
        #"{"type":"error","code":"\#(code)","message":"\#(message)"}"#
    }

    // MARK: - 方案用量

    @Test("Codex 方案用量:送 usage.codex,週期依回應")
    func codexUsage() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let usage = try await Self.connection(service).codexUsage()

        #expect(usage.periods == [
            .init(kind: .fiveHour, usedPercentage: 42.5, resetsAt: "2026-11-22T05:30:00Z"),
            .init(kind: .week, usedPercentage: 12.0),
        ])
        #expect(service.messages(ofType: "usage.codex").count == 1)
    }

    @Test("Claude 方案用量:帶 installed 與擷取時間")
    func claudeUsage() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let usage = try await Self.connection(service).claudeUsage()

        #expect(usage.installed)
        #expect(usage.capturedAt == "2026-11-22T03:00:00Z")
        #expect(usage.periods.map(\.kind) == [.fiveHour, .week])
    }

    @Test("Codex 的錯誤碼各換成專屬錯誤", arguments: [
        ("codex_not_found", PlanUsageError.codexNotFound),
        ("codex_not_signed_in", .codexNotSignedIn),
        ("codex_failed", .codexFailed("failed")),
    ])
    func codexErrors(code: String, expected: PlanUsageError) async throws {
        let service = try await Self.start(["usage.codex": [Self.errorReply(code)]])
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        await #expect(throws: expected) { try await connection.codexUsage() }
    }

    // MARK: - session context

    @Test("session context:送 session_ids,回各 session 的用量")
    func sessionContexts() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let id = "5d1c9f0e-3b7a-4c52-9a41-0e8f6d2b7c13"

        let contexts = try await Self.connection(service).sessionContexts(sessionIDs: [id])

        #expect(contexts == [.init(sessionId: id, capturedAt: "2026-11-22T03:00:00Z", usedPercentage: 23.5, contextWindowSize: 200000)])
        let sent = try #require(service.messages(ofType: "usage.session_context").first)
        #expect(sent["session_ids"] as? [String] == [id])
    }

    // MARK: - 用量擷取

    @Test("用量擷取的狀態、安裝、還原各送對應訊息,回安裝後狀態")
    func claudeUsageSetup() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        let status = try await connection.claudeUsageStatus()
        let installed = try await connection.installClaudeUsage()
        let removed = try await connection.removeClaudeUsage()

        #expect(status.claudeFound)
        #expect(installed.installed && installed.wrapperActive && installed.claudeFound)
        #expect(!removed.wrapperActive)
        for type in ["claude_usage.status", "claude_usage.install", "claude_usage.remove"] {
            #expect(service.messages(ofType: type).count == 1, "\(type)")
        }
    }

    @Test("安裝的錯誤碼各換成專屬錯誤", arguments: [
        ("claude_not_found", PlanUsageError.claudeNotFound),
        ("claude_settings_not_json", .claudeSettingsNotJSON),
        ("host_write_failed", .hostWriteFailed("failed")),
    ])
    func installErrors(code: String, expected: PlanUsageError) async throws {
        let service = try await Self.start(["claude_usage.install": [Self.errorReply(code)]])
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        await #expect(throws: expected) { try await connection.installClaudeUsage() }
    }

    @Test("唯讀裝置:狀態與用量可讀,安裝與還原被拒(read_only_device)")
    func readOnlyDeviceCannotInstall() async throws {
        let service = try await Self.start(readOnly: true)
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        _ = try await connection.claudeUsageStatus()
        _ = try await connection.claudeUsage()
        await #expect(throws: HostServiceError.readOnlyDevice) { try await connection.installClaudeUsage() }
        await #expect(throws: HostServiceError.readOnlyDevice) { try await connection.removeClaudeUsage() }
    }

    @Test("安裝與還原在協定裡是寫入類,狀態不是(UI 測試替身依它擋唯讀)")
    func installAndRemoveAreWrites() {
        let install = HostServiceProtocol.ClientMessage.claudeUsageInstall(.init(requestId: "r"))
        let remove = HostServiceProtocol.ClientMessage.claudeUsageRemove(.init(requestId: "r"))
        let status = HostServiceProtocol.ClientMessage.claudeUsageStatus(.init(requestId: "r"))
        #expect(install.isWrite && remove.isWrite && !status.isWrite)
    }

    // MARK: - 資料夾瀏覽

    @Test("資料夾瀏覽:送絕對路徑,回子資料夾名稱")
    func listDirectory() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let listing = try await Self.connection(service).listDirectory(path: "/Users/demo/Projects")

        #expect(listing.directories == [".github", "garden-journal", "Ledger"])
        #expect(!listing.truncated)
        let sent = try #require(service.messages(ofType: "directory.list").first)
        #expect(sent["path"] as? String == "/Users/demo/Projects")
    }

    @Test("資料夾瀏覽的錯誤碼各換成專屬錯誤", arguments: [
        ("directory_not_found", DirectoryListError.notFound),
        ("directory_not_allowed", .notAllowed),
        ("directory_unreadable", .unreadable),
    ])
    func directoryErrors(code: String, expected: DirectoryListError) async throws {
        let service = try await Self.start(["directory.list": [Self.errorReply(code)]])
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        await #expect(throws: expected) { try await connection.listDirectory(path: "/Users/demo/x") }
    }

    @Test("welcome 帶家目錄")
    func homeDirectory() async throws {
        let service = try await Self.start(home: "/Users/demo")
        defer { Task { await service.stop() } }

        #expect(try await Self.connection(service).homeDirectory() == "/Users/demo")
    }

    @Test("workspace.create 資料夾不存在:0.12.0 的 directory_not_found 也是 folder_not_found")
    func createWorkspaceInMissingFolder() async throws {
        var settings = FakeHostService.Settings(hostServiceVersion: "0.12.0")
        settings.missingFolders = ["/Users/demo/gone"]
        let service = try await FakeHostService.start(settings)
        defer { Task { await service.stop() } }
        let client = HerdrClient(connection: Self.connection(service))

        await #expect {
            _ = try await client.createWorkspace(cwd: "/Users/demo/gone", label: nil)
        } throws: { error in
            if case HerdrError.herdr(code: "folder_not_found", _) = error { return true }
            return false
        }
    }

    // MARK: - 版本門檻

    @Test("0.11.x 主機服務:每個新請求都不送出,要求更新主機服務(不是不支援)")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await Self.start(version: "0.11.0")
        defer { Task { await service.stop() } }
        let connection = Self.connection(service)

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.planUsage, installedVersion: "0.11.0")) { try await connection.codexUsage() }
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.planUsage, installedVersion: "0.11.0")) { try await connection.claudeUsage() }
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.sessionContext, installedVersion: "0.11.0")) {
            try await connection.sessionContexts(sessionIDs: ["a"])
        }
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.claudeUsageSetup, installedVersion: "0.11.0")) { try await connection.claudeUsageStatus() }
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.claudeUsageSetup, installedVersion: "0.11.0")) { try await connection.installClaudeUsage() }
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.claudeUsageSetup, installedVersion: "0.11.0")) { try await connection.removeClaudeUsage() }
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.directoryBrowsing, installedVersion: "0.11.0")) {
            try await connection.listDirectory(path: "/")
        }
        #expect(try await connection.homeDirectory() == nil)
        for type in ["usage.codex", "usage.claude", "usage.session_context", "claude_usage.status", "claude_usage.install", "claude_usage.remove", "directory.list"] {
            #expect(service.messages(ofType: type).isEmpty, "\(type)")
        }
    }
}
