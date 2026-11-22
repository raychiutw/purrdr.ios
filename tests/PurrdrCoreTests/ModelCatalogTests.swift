import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 模型目錄三層來源(#385):主機快取 → 公開目錄 → 內建對照表。
@Suite("模型目錄:三層來源與解析")
struct ModelCatalogTests {
    static let hostCache = Fixtures.modelCatalog("host-cache-cc.json")
    static let publicCatalog = Fixtures.modelCatalog("public-catalog.json")

    // MARK: - 解析

    @Test("主機快取:模型、描述、各模型的 effort,Max 帶使用量倍率警示、Medium 是推薦")
    func parsesHostCache() throws {
        let catalog = try #require(ModelCatalogParser.parse(Self.hostCache))
        let opus = try #require(catalog.entry(id: "claude-opus-5-5"))
        #expect(opus.name == "Opus 5.5")
        #expect(opus.description == "For complex work and everyday tasks")
        #expect(opus.effortOptions.map(\.id) == ["low", "medium", "high", "xhigh", "max"])
        #expect(opus.effort("medium")?.badge == ModelBadge(message: "Recommended", variant: .neutral))
        #expect(opus.effort("max")?.badge == ModelBadge(message: "3.5× or more usage", variant: .warning))
        #expect(opus.supportsXHigh)
        // Sonnet 的 Max 沒有倍率徽章:取不到的欄位不顯示。
        #expect(catalog.entry(id: "claude-sonnet-5-5")?.effort("max")?.badge == nil)
    }

    @Test("不支援 effort 的舊模型沒有層級、也不支援 Ultracode;overflow 區的模型標為 overflow")
    func parsesOverflowAndNoEffort() throws {
        let catalog = try #require(ModelCatalogParser.parse(Self.hostCache))
        let haiku = try #require(catalog.entry(id: "claude-haiku-4-5-20251001"))
        #expect(haiku.effortOptions.isEmpty)
        #expect(!haiku.supportsXHigh)
        #expect(haiku.section == "overflow")
        #expect(catalog.entry(id: "claude-opus-4-6")?.supportsXHigh == false)
    }

    @Test("公開目錄(surfaces.cc.model_selector_config)與主機快取解出同樣的主要模型")
    func parsesPublicCatalog() throws {
        let host = try #require(ModelCatalogParser.parse(Self.hostCache))
        let published = try #require(ModelCatalogParser.parse(Self.publicCatalog))
        for id in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] {
            #expect(published.entry(id: id)?.name == host.entry(id: id)?.name)
        }
        // 公開目錄沒有 Max 的倍率徽章(只有 tooltip):取不到就不顯示。
        #expect(published.entry(id: "claude-opus-5-5")?.effort("medium")?.badge?.message == "Recommended")
        #expect(published.entry(id: "claude-opus-5-5")?.effort("max")?.badge == nil)
    }

    @Test("以 id(含 [1m] 與前綴)或面板列名稱找模型")
    func lookups() throws {
        let catalog = try #require(ModelCatalogParser.parse(Self.hostCache))
        #expect(catalog.entry(id: "claude-opus-5-5[1m]")?.id == "claude-opus-5-5")
        #expect(catalog.entry(id: "anthropic/claude-opus-5-5")?.id == "claude-opus-5-5")
        #expect(catalog.entry(named: "Opus 5.5")?.id == "claude-opus-5-5")
        #expect(catalog.entry(named: " opus ")?.id == "claude-opus-5-5")
        #expect(catalog.entry(named: "Default (recommended)") == nil)
    }

    @Test("壞掉的內容回 nil:非 JSON、沒有 models、全部缺欄位;缺欄位的單筆略過")
    func corruptInputs() throws {
        #expect(ModelCatalogParser.parse(Data("not json".utf8)) == nil)
        #expect(ModelCatalogParser.parse(Data("{}".utf8)) == nil)
        #expect(ModelCatalogParser.parse(Data(#"{"catalog":{"config":{"models":[{"name":"x"}]}}}"#.utf8)) == nil)
        #expect(ModelCatalogParser.parse(Self.hostCache.prefix(500)) == nil)
        let partial = Data(#"{"catalog":{"config":{"models":[{"name":"x"},{"id":"claude-a-1","name":"A 1"}]}}}"#.utf8)
        #expect(ModelCatalogParser.parse(partial)?.models.map(\.id) == ["claude-a-1"])
    }

    @Test("內建對照表有名稱與層級,沒有任何徽章;核心不放顯示字串——沒有描述,層級名稱只是識別(英文與繁中在 Features)")
    func builtInHasNoBadges() throws {
        let opus = try #require(ModelCatalog.builtIn.entry(id: "claude-opus-5-5"))
        #expect(opus.description == nil)
        #expect(ModelCatalog.builtIn.models.allSatisfy { $0.effortOptions.allSatisfy { $0.name == $0.id } })
        #expect(opus.supportsXHigh)
        #expect(ModelCatalog.builtIn.models.allSatisfy { $0.badge == nil && $0.effortOptions.allSatisfy { $0.badge == nil } })
    }

    // MARK: - 三層依序退回

    struct HostReader: HostModelCatalogReading {
        var result: Result<Data?, any Error>
        func readCache() async throws -> Data? { try result.get() }
    }

    struct PublicFetcher: PublicModelCatalogFetching {
        var result: Result<Data, any Error>
        func fetch() async throws -> Data { try result.get() }
    }

    struct Unavailable: Error {}

    static func resolve(host: Result<Data?, any Error>?, publicCatalog: Result<Data, any Error>?) async -> ResolvedModelCatalog {
        await ModelCatalogResolver(host: host.map(HostReader.init), publicCatalog: publicCatalog.map(PublicFetcher.init)).catalog()
    }

    @Test("主機快取可用:用主機快取,不碰公開目錄")
    func hostCacheWins() async {
        let resolved = await Self.resolve(host: .success(Self.hostCache), publicCatalog: .failure(Unavailable()))
        #expect(resolved.source == .hostCache)
        #expect(resolved.catalog.entry(id: "claude-opus-5-5")?.effort("max")?.badge != nil)
    }

    @Test("主機快取損壞:退到公開目錄")
    func corruptHostCacheFallsBackToPublic() async {
        let resolved = await Self.resolve(host: .success(Data("{\"catalog\":".utf8)), publicCatalog: .success(Self.publicCatalog))
        #expect(resolved.source == .publicCatalog)
    }

    @Test("主機快取不存在:退到公開目錄")
    func missingHostCacheFallsBackToPublic() async {
        let resolved = await Self.resolve(host: .success(nil), publicCatalog: .success(Self.publicCatalog))
        #expect(resolved.source == .publicCatalog)
    }

    @Test("主機讀取失敗(Windows、HTTPS、逾時):退到公開目錄")
    func hostFailureFallsBackToPublic() async {
        let resolved = await Self.resolve(host: .failure(Unavailable()), publicCatalog: .success(Self.publicCatalog))
        #expect(resolved.source == .publicCatalog)
    }

    @Test("公開目錄不可用(連不上或內容壞掉):退到內建對照表,不報錯")
    func publicUnavailableFallsBackToBuiltIn() async {
        let offline = await Self.resolve(host: .success(nil), publicCatalog: .failure(Unavailable()))
        #expect(offline.source == .builtIn)
        #expect(offline.catalog == .builtIn)
        let corrupt = await Self.resolve(host: .success(Data("x".utf8)), publicCatalog: .success(Data("<html>".utf8)))
        #expect(corrupt.source == .builtIn)
    }

    @Test("沒有任何來源可問:內建對照表")
    func noSourcesUsesBuiltIn() async {
        #expect(await Self.resolve(host: nil, publicCatalog: nil).source == .builtIn)
    }

    // MARK: - 專用唯讀指令(對真的 /bin/sh)

    static let cachePath = ".claude/cache/model-catalog"

    @Test("專用指令讀最新的 *-cc.json:不讀 published-*、-ccd.json,也不碰家目錄裡的其他檔案")
    func commandReadsOnlyNewestCatalogCache() async throws {
        let host = try LocalShellHost.temporary()
        let old = try host.write(Data(#"{"old":true}"#.utf8), to: "\(Self.cachePath)/aaaa-bbbb-cc.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        try host.write(Self.hostCache, to: "\(Self.cachePath)/tok-new-cc.json")
        try host.write(Data("PUBLISHED".utf8), to: "\(Self.cachePath)/published-x.json")
        try host.write(Data("DESKTOP".utf8), to: "\(Self.cachePath)/tok-zzz-ccd.json")
        try host.write(Data("SECRET".utf8), to: ".claude/settings.json")

        let data = try #require(try await SSHModelCatalogReader(channel: host).readCache())
        #expect(data == Self.hostCache)
        #expect(ModelCatalogParser.parse(data) != nil)
    }

    @Test("專用指令:沒有快取資料夾時回 nil(不是錯誤);指令本身不接受路徑參數")
    func commandWithoutCache() async throws {
        let host = try LocalShellHost.temporary()
        #expect(try await SSHModelCatalogReader(channel: host).readCache() == nil)
        #expect(!ModelCatalogCommand.script.contains("$1") && !ModelCatalogCommand.script.contains("$@"))
    }

    @Test("完整三層:主機有快取就用主機的")
    func endToEndHostCache() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Self.hostCache, to: "\(Self.cachePath)/tok-a-cc.json")
        let resolved = await ModelCatalogResolver(host: SSHModelCatalogReader(channel: host), publicCatalog: nil).catalog()
        #expect(resolved.source == .hostCache)
    }
}
