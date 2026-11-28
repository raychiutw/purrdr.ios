/// 推播種類的代號(raychiutw/purrdr.server#10 的 `kinds`、#39 起的 `GET /v1/push-kinds`);原始值就是 wire 上的值。
///
/// 種類清單由後台提供(ADR-0016),所以這不是固定的列舉:後台新增的種類 app 也讀得進來、能顯示與開關。
/// 下面的常數只是 app 內建備援(舊後台沒有清單 API)與測試用,不是「支援的種類」的完整清單。
/// 主機外掛照樣送每個狀態，由後台依配對的種類決定是否轉 APNs,所以主機端不需要知道。
public struct PushKind: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// 「需要你」:Agent 進入 `blocked`。
    public static let blocked = PushKind("blocked")
    /// 「完成」:Agent 進入 `done`。
    public static let done = PushKind("done")
    /// 「可能卡住」:主機服務的 Agent 觀察者看到 working 的 Agent 畫面 10 分鐘沒變(raychiutw/purrdr.server#15、purrdr.host#31)。
    public static let stuck = PushKind("stuck")
    /// 「仍在等你」:Agent 停在 `blocked` 15 分鐘(錯過「需要你」後再提醒一次)。
    public static let reminder = PushKind("reminder")
    /// 「主機服務」:主機服務的更新事件(有新版、已更新、已退回;raychiutw/purrdr.server#11)。
    public static let hostService = PushKind("host_service")
    /// 「每日上限已達」:今日通知則數用完時的說明(#675);會員層級,後台依這組配對的開關決定送不送。
    public static let dailyLimitReached = PushKind("daily_limit_reached")

    /// wire 上的陣列：依代號排序，讓同一組種類每次送出都一樣。
    public static func wireValues(_ kinds: Set<PushKind>) -> [String] {
        kinds.map(\.rawValue).sorted()
    }
}

/// 後台給的一段兩種語言的文字(`{en, "zh-Hant"}`)。
public struct PushLocalizedText: Sendable, Equatable {
    public var english: String
    public var traditionalChinese: String?

    public init(english: String, traditionalChinese: String? = nil) {
        self.english = english
        self.traditionalChinese = traditionalChinese
    }

    /// 依語言偏好(例如 `Bundle.main.preferredLocalizations`)選文字:繁體中文優先、其餘用英文;缺的語言退回另一種。
    public func resolved(preferredLanguages: [String]) -> String {
        let prefersChinese = preferredLanguages.first.map(Self.isTraditionalChinese) ?? false
        let chosen = prefersChinese ? (traditionalChinese ?? english) : english
        return chosen.isEmpty ? (traditionalChinese ?? "") : chosen
    }

    private static func isTraditionalChinese(_ language: String) -> Bool {
        let lowered = language.lowercased()
        return ["zh-hant", "zh-tw", "zh-hk", "zh-mo"].contains { lowered.hasPrefix($0) }
    }
}

/// 一種推播適用的連線方式(後台 `transports` 的值;不認得的值略過)。
public enum PushTransport: String, Sendable, Hashable {
    case ssh
    case https
}

/// 後台種類清單的一項(`GET /v1/push-kinds`)。
public struct PushKindDefinition: Sendable, Equatable, Identifiable {
    public var kind: PushKind
    public var name: PushLocalizedText
    public var description: PushLocalizedText
    /// 新配對預設開不開。
    public var defaultOn: Bool
    /// 適用的連線方式;`nil` 是不限(後台沒給或給空陣列)。
    public var transports: Set<PushTransport>?
    /// 需要的主機服務最低版本(只對 HTTPS 主機有意義)。
    public var minServiceVersion: HostServiceVersion?
    /// 需要的主機外掛最低版本(只對 SSH 主機有意義)。
    public var minPluginVersion: HostServiceVersion?
    public var order: Int

    public var id: String { kind.rawValue }

    public init(
        kind: PushKind, name: PushLocalizedText, description: PushLocalizedText, defaultOn: Bool,
        transports: Set<PushTransport>? = nil, minServiceVersion: HostServiceVersion? = nil,
        minPluginVersion: HostServiceVersion? = nil, order: Int
    ) {
        self.kind = kind
        self.name = name
        self.description = description
        self.defaultOn = defaultOn
        self.transports = transports
        self.minServiceVersion = minServiceVersion
        self.minPluginVersion = minPluginVersion
        self.order = order
    }

    /// 這個種類在某台主機能不能開。
    public func availability(
        installsViaHostService: Bool, hostServiceVersion: HostServiceVersion?, pluginVersion: HostServiceVersion? = nil
    ) -> PushKindAvailability {
        if let transports {
            let transport: PushTransport = installsViaHostService ? .https : .ssh
            if !transports.contains(transport) {
                // 只開放給 HTTPS 的種類:SSH 主機要裝主機服務才有;反過來(只給 SSH)沒有下一步。
                return transports.contains(.https) ? .needsHostService : .unsupportedConnection
            }
        }
        // 版本未知(還沒連上)時不擋。
        if installsViaHostService, let minimum = minServiceVersion, let installed = hostServiceVersion, installed < minimum {
            return .needsHostServiceUpdate(minimum: minimum)
        }
        if !installsViaHostService, let minimum = minPluginVersion, let installed = pluginVersion, installed < minimum {
            return .needsPluginUpdate(minimum: minimum)
        }
        return .available
    }
}

/// 某個種類在某台主機的可用性。
public enum PushKindAvailability: Sendable, Equatable {
    case available
    /// SSH 主機:這種通知要裝主機服務(HTTPS 連線)。
    case needsHostService
    /// 主機服務太舊。
    case needsHostServiceUpdate(minimum: HostServiceVersion)
    /// 主機外掛太舊。
    case needsPluginUpdate(minimum: HostServiceVersion)
    /// 這種連線方式沒有這種通知。
    case unsupportedConnection

    public var isAvailable: Bool { self == .available }
}

/// 一次取得的種類清單。
public struct PushKindCatalog: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// app 內建備援(離線、舊後台或還沒讀到)。
        case builtIn
        case backend
    }

    /// 依 `order` 排序(同序依代號)。
    public let definitions: [PushKindDefinition]
    public let source: Source

    public init(definitions: [PushKindDefinition], source: Source) {
        self.definitions = definitions.sorted { ($0.order, $0.kind.rawValue) < ($1.order, $1.kind.rawValue) }
        self.source = source
    }

    public func definition(for kind: PushKind) -> PushKindDefinition? {
        definitions.first { $0.kind == kind }
    }

    /// 這台主機可選(含停用但看得到的)的種類:連線方式不符、沒有下一步的才隱藏。
    public func choices(installsViaHostService: Bool) -> [PushKindDefinition] {
        definitions.filter {
            $0.availability(installsViaHostService: installsViaHostService, hostServiceVersion: nil) != .unsupportedConnection
        }
    }

    /// 新配對預設要收的種類:預設開、而且這台主機現在就能用的。
    public func defaultKinds(installsViaHostService: Bool, hostServiceVersion: HostServiceVersion?) -> Set<PushKind> {
        Set(definitions.filter {
            $0.defaultOn && $0.availability(installsViaHostService: installsViaHostService, hostServiceVersion: hostServiceVersion).isAvailable
        }.map(\.kind))
    }
}

/// 後台的一組推播配對(`GET /v1/members/me/push-pairings`):配對以後台為準。
public struct PushPairingRecord: Sendable, Equatable {
    public var keyHash: String
    public var name: String?
    public var kinds: Set<PushKind>

    public init(keyHash: String, name: String? = nil, kinds: Set<PushKind>) {
        self.keyHash = keyHash
        self.name = name
        self.kinds = kinds
    }
}
