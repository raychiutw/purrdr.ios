import Foundation

/// 模型目錄(#385):模型清單、描述、各模型支援的 effort、「推薦」與使用量倍率徽章。
///
/// 三層來源依序退回(`ModelCatalogResolver`):
/// 1. 主機上 Claude Code 的模型目錄快取(`ModelCatalogCommand` 專用唯讀指令讀取;它不在 Agent 工作目錄下，現有取檔規則不允許)。
/// 2. 公開模型目錄(`PublicModelCatalog.url`)。
/// 3. 內建對照表(`ModelCatalog.builtIn`):只有名稱、描述與層級,**不含徽章**——取不到的欄位不顯示、不寫死。
/// 解析失敗不報錯,直接退到下一層。
public struct ModelCatalog: Sendable, Equatable {
    public var models: [ModelCatalogEntry]

    public init(models: [ModelCatalogEntry]) {
        self.models = models
    }

    /// 以模型 id 找(忽略 `[1m]` 之類的尾註與前綴)。
    public func entry(id: String) -> ModelCatalogEntry? {
        let wanted = Self.normalized(id: id)
        return models.first { $0.id == wanted }
    }

    /// 以面板列的名稱找(名稱、簡稱或 id 相符,不分大小寫與前後空白)。
    public func entry(named label: String) -> ModelCatalogEntry? {
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return models.first { entry in
            [entry.name, entry.id].contains { $0.lowercased() == wanted }
        } ?? models.first { $0.shortName?.lowercased() == wanted }
    }

    static func normalized(id: String) -> String {
        var id = id.lastIndex(of: "/").map { String(id[id.index(after: $0)...]) } ?? id
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        return id
    }
}

public struct ModelCatalogEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var shortName: String?
    /// 目錄的英文描述(繁中由畫面端以模型 id 對照的內建表提供)。
    public var description: String?
    /// `main` 或 `overflow`(「更多模型」)。
    public var section: String?
    public var badge: ModelBadge?
    /// 此模型支援的 effort(依序);不支援 effort 的模型是空陣列。
    public var effortOptions: [EffortOption]

    public init(
        id: String, name: String, shortName: String? = nil, description: String? = nil, section: String? = nil,
        badge: ModelBadge? = nil, effortOptions: [EffortOption] = []
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.description = description
        self.section = section
        self.badge = badge
        self.effortOptions = effortOptions
    }

    public func effort(_ level: String) -> EffortOption? {
        effortOptions.first { $0.id.lowercased() == level.lowercased() }
    }

    /// 支援 xhigh:Ultracode 開關才會出現。
    public var supportsXHigh: Bool { effort("xhigh") != nil }
}

public struct EffortOption: Sendable, Equatable {
    public var id: String
    public var name: String
    public var badge: ModelBadge?

    public init(id: String, name: String, badge: ModelBadge? = nil) {
        self.id = id
        self.name = name
        self.badge = badge
    }
}

/// 目錄的徽章:`message` 是英文原文(「Recommended」「3.5× or more usage」),`variant` 決定警示樣式。
public struct ModelBadge: Sendable, Equatable {
    public enum Variant: Sendable, Equatable {
        case neutral
        /// 使用量倍率等警示(畫面:主要色文字加橙色三角形)。
        case warning
        case other
    }

    public var message: String
    public var variant: Variant

    public init(message: String, variant: Variant) {
        self.message = message
        self.variant = variant
    }
}

/// 解析模型目錄文件。容錯:缺欄位的模型略過、沒有任何可用模型回 `nil`。
public enum ModelCatalogParser {
    public static func parse(_ data: Data) -> ModelCatalog? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = models(in: root)
        else { return nil }
        let entries = models.compactMap(entry(from:))
        return entries.isEmpty ? nil : ModelCatalog(models: entries)
    }

    /// 主機快取:`catalog.config.models`;公開目錄:`surfaces.cc.model_selector_config[0].models`。
    private static func models(in root: [String: Any]) -> [[String: Any]]? {
        if let catalog = root["catalog"] as? [String: Any], let config = catalog["config"] as? [String: Any],
           let models = config["models"] as? [[String: Any]] {
            return models
        }
        if let surfaces = root["surfaces"] as? [String: Any], let cc = surfaces["cc"] as? [String: Any] {
            if let configs = cc["model_selector_config"] as? [[String: Any]] {
                return configs.compactMap { $0["models"] as? [[String: Any]] }.first
            }
            if let config = cc["model_selector_config"] as? [String: Any] { return config["models"] as? [[String: Any]] }
        }
        return nil
    }

    private static func entry(from object: [String: Any]) -> ModelCatalogEntry? {
        guard let id = object["id"] as? String, !id.isEmpty, let name = object["name"] as? String, !name.isEmpty else { return nil }
        let thinking = object["thinking"] as? [String: Any]
        let options = (thinking?["effort_options"] as? [[String: Any]] ?? []).compactMap { option -> EffortOption? in
            guard let optionID = option["id"] as? String, !optionID.isEmpty else { return nil }
            return EffortOption(id: optionID, name: option["name"] as? String ?? optionID, badge: badge(from: option["badge"]))
        }
        return ModelCatalogEntry(
            id: id, name: name, shortName: object["short_name"] as? String, description: object["description"] as? String,
            section: object["section"] as? String, badge: badge(from: object["badge"]), effortOptions: options)
    }

    private static func badge(from value: Any?) -> ModelBadge? {
        guard let object = value as? [String: Any], let message = object["message"] as? String, !message.isEmpty else { return nil }
        let variant: ModelBadge.Variant = switch object["variant"] as? String {
        case "neutral": .neutral
        case "warning": .warning
        default: .other
        }
        return ModelBadge(message: message, variant: variant)
    }
}

extension ModelCatalog {
    /// 內建對照表(第三層):只有名稱、英文描述與層級,不含徽章。
    public static let builtIn = ModelCatalog(models: [
        builtInEntry("claude-opus-5-5", "Opus 5.5", "Opus", "For complex work and everyday tasks"),
        builtInEntry("claude-sonnet-5-5", "Sonnet 5.5", "Sonnet", "Most efficient for simpler tasks"),
        builtInEntry("claude-fable-5-2", "Fable 5.2", "Fable", "For your toughest challenges"),
        builtInEntry("claude-haiku-5-5", "Haiku 5.5", "Haiku", "Fastest for quick answers"),
    ])

    private static func builtInEntry(_ id: String, _ name: String, _ shortName: String, _ description: String) -> ModelCatalogEntry {
        let levels = [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra"), ("max", "Max")]
        return ModelCatalogEntry(
            id: id, name: name, shortName: shortName, description: description, section: "main",
            effortOptions: levels.map { EffortOption(id: $0.0, name: $0.1) })
    }
}

/// 目錄從哪一層來(測試與診斷用)。
public enum ModelCatalogSource: Sendable, Equatable {
    case hostCache
    case publicCatalog
    case builtIn
}

public struct ResolvedModelCatalog: Sendable, Equatable {
    public var catalog: ModelCatalog
    public var source: ModelCatalogSource

    public init(catalog: ModelCatalog, source: ModelCatalogSource) {
        self.catalog = catalog
        self.source = source
    }
}

/// 讀主機上的目錄快取(原始 JSON);沒有快取回 `nil`,讀不到丟錯。
public protocol HostModelCatalogReading: Sendable {
    func readCache() async throws -> Data?
}

/// 取公開模型目錄(原始 JSON)。
public protocol PublicModelCatalogFetching: Sendable {
    func fetch() async throws -> Data
}

public enum PublicModelCatalog {
    /// Claude Code 自己使用的公開目錄(簽章文件;app 只當作顯示用資料讀取,不驗簽)。
    public static let url = URL(string: "https://downloads.claude.ai/model-catalog/v1/catalog.json")!
}

/// 提供模型目錄給畫面 model。
public protocol ModelCatalogProviding: Sendable {
    func catalog() async -> ResolvedModelCatalog
}

/// 三層依序退回:主機快取 → 公開目錄 → 內建對照表。任何一層讀不到、解析失敗或取消都退到下一層,不報錯。
public struct ModelCatalogResolver: ModelCatalogProviding {
    private let host: (any HostModelCatalogReading)?
    private let publicCatalog: (any PublicModelCatalogFetching)?
    private let builtIn: ModelCatalog

    public init(
        host: (any HostModelCatalogReading)?, publicCatalog: (any PublicModelCatalogFetching)?, builtIn: ModelCatalog = .builtIn
    ) {
        self.host = host
        self.publicCatalog = publicCatalog
        self.builtIn = builtIn
    }

    public func catalog() async -> ResolvedModelCatalog {
        if let host, let data = try? await host.readCache(), let catalog = ModelCatalogParser.parse(data) {
            return ResolvedModelCatalog(catalog: catalog, source: .hostCache)
        }
        if !Task.isCancelled, let publicCatalog, let data = try? await publicCatalog.fetch(), let catalog = ModelCatalogParser.parse(data) {
            return ResolvedModelCatalog(catalog: catalog, source: .publicCatalog)
        }
        return ResolvedModelCatalog(catalog: builtIn, source: .builtIn)
    }
}

/// 專用唯讀指令:只讀 Claude Code 的模型目錄快取(`<設定資料夾>/cache/model-catalog/` 下最新的 `*-cc.json`),
/// 不接受任何路徑參數,所以不放寬主機取檔的存取規則。沒有快取時什麼都不印、exit 0。
public enum ModelCatalogCommand {
    /// 快取檔的大小上限(實際約 16 KB)。
    public static let maximumBytes = 524_288

    public static func command() -> String {
        TranscriptCommand.command(script, arguments: [])
    }

    package static let script = #"""
        d=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/model-catalog
        f=$(ls -t "$d"/*-cc.json 2>/dev/null | head -n 1)
        if [ -n "$f" ] && [ -f "$f" ]; then head -c 524288 "$f"; fi
        """#
}
