import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機的 slash 清單(#733、主機服務 0.17.0 的 `slash.list`):經假主機服務 WebSocket 驗證。
@Suite("HTTPS 主機的 slash 清單")
struct HTTPSSlashListTests {
    private static func start(_ replies: [String: [String]] = [:], version: String = "0.17.0") async throws -> FakeHostService {
        var settings = FakeHostService.Settings(hostServiceVersion: version)
        settings.usageReplies = replies
        return try await FakeHostService.start(settings)
    }

    private static func discovery(_ service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    @Test("清單:內建指令之外列出使用者與 plugin 的項目,plugin 依名稱分組")
    func listsUserAndPluginCommands() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }

        let catalog = await Self.discovery(service).catalog(cwd: "/work", transcriptPath: nil)

        #expect(catalog.isComplete)
        #expect(catalog.sections.map(\.source) == [.builtIn, .user, .plugin("mattpocock-skills")])
        let user = try #require(catalog.sections.first { $0.source == .user })
        #expect(user.commands == [
            SlashCommand(name: "db:migrate", summary: "Run the migrations"),
            SlashCommand(name: "deploy", argumentHint: "<environment>", summary: "Deploy the app"),
        ])
        let plugin = try #require(catalog.sections.last)
        #expect(plugin.commands.map(\.name) == ["mattpocock-skills:tdd"])
        #expect(service.messages(ofType: "slash.list").count == 1)
    }

    @Test("內建指令的優先序高於同名的使用者項目")
    func builtInWinsOverUser() async throws {
        let builtIn = try #require(ClaudeBuiltinCommands.all.first).name
        let reply = #"{"type":"slash.list.result","commands":[{"name":"\#(builtIn)","summary":"mine","source":"user"}],"disabled_plugins":[],"truncated":false}"#
        let service = try await Self.start(["slash.list": [reply]])
        defer { Task { await service.stop() } }

        let catalog = await Self.discovery(service).catalog(cwd: nil, transcriptPath: nil)

        #expect(catalog.sections.map(\.source) == [.builtIn])
        #expect(catalog.sections[0].commands.filter { $0.name == builtIn }.count == 1)
    }

    @Test("主機回報清單被截斷:標示為不完整")
    func truncatedIsIncomplete() async throws {
        let reply = #"{"type":"slash.list.result","commands":[],"disabled_plugins":["x"],"truncated":true}"#
        let service = try await Self.start(["slash.list": [reply]])
        defer { Task { await service.stop() } }

        let catalog = await Self.discovery(service).catalog(cwd: nil, transcriptPath: nil)

        #expect(!catalog.isComplete)
        #expect(catalog.sections.map(\.source) == [.builtIn])
    }

    @Test("舊版主機服務(0.17.0 以前):不送出,退回只有內建指令且標示不完整")
    func oldHostServiceFallsBackToBuiltIn() async throws {
        let service = try await Self.start(version: "0.16.0")
        defer { Task { await service.stop() } }

        let catalog = await Self.discovery(service).catalog(cwd: nil, transcriptPath: nil)

        #expect(catalog == SlashCatalog(sections: [SlashSection(source: .builtIn, commands: ClaudeBuiltinCommands.all)], isComplete: false))
        #expect(service.messages(ofType: "slash.list").isEmpty)
    }

    @Test("主機回錯誤:退回只有內建指令且標示不完整")
    func errorFallsBackToBuiltIn() async throws {
        let service = try await Self.start(["slash.list": [#"{"type":"error","code":"internal","message":"x"}"#]])
        defer { Task { await service.stop() } }

        let catalog = await Self.discovery(service).catalog(cwd: nil, transcriptPath: nil)

        #expect(!catalog.isComplete)
        #expect(catalog.sections.map(\.source) == [.builtIn])
    }

    @Test("功能門檻:slash 清單從主機服務 0.17.0 起")
    func minimumVersion() {
        #expect(HostServiceFeature.slashList.minimumVersion == HostServiceVersion(0, 17, 0))
        #expect(!HostServiceFeature.slashList.isAvailable(onHostServiceVersion: "0.16.0"))
        #expect(HostServiceFeature.slashList.isAvailable(onHostServiceVersion: "0.17.0"))
    }
}
