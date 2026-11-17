// 由 protocol/host-service.schema.json 產生，不要手動修改。重新產生:cd host-service && cargo run -p protocol-codegen

import Foundation

/// 主機服務協定(ADR-0010)的訊息型別。
public enum HostServiceProtocol {
    /// 協定版本(schema 的 `x-protocol-version`)。
    public static let version = 1
}

extension HostServiceProtocol {
    /// app 送給主機服務的訊息，以 type 區分。標 x-write 的是寫入類操作，唯讀裝置送出時被拒絕(read_only_device)。
    public enum ClientMessage: Codable, Sendable, Equatable {
        case hello(Hello)
        case agentsList(AgentsList)
        case paneSendKeys(PaneSendKeys)
        case eventsSubscribe(EventsSubscribe)
        case eventsUnsubscribe(EventsUnsubscribe)

        private enum TypeKey: String, CodingKey {
            case type
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TypeKey.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "hello": self = .hello(try Hello(from: decoder))
            case "agents.list": self = .agentsList(try AgentsList(from: decoder))
            case "pane.send_keys": self = .paneSendKeys(try PaneSendKeys(from: decoder))
            case "events.subscribe": self = .eventsSubscribe(try EventsSubscribe(from: decoder))
            case "events.unsubscribe": self = .eventsUnsubscribe(try EventsUnsubscribe(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown message type \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: TypeKey.self)
            switch self {
            case .hello(let message):
                try container.encode("hello", forKey: .type)
                try message.encode(to: encoder)
            case .agentsList(let message):
                try container.encode("agents.list", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendKeys(let message):
                try container.encode("pane.send_keys", forKey: .type)
                try message.encode(to: encoder)
            case .eventsSubscribe(let message):
                try container.encode("events.subscribe", forKey: .type)
                try message.encode(to: encoder)
            case .eventsUnsubscribe(let message):
                try container.encode("events.unsubscribe", forKey: .type)
                try message.encode(to: encoder)
            }
        }

        /// 寫入類訊息(schema 的 `x-write`);唯讀裝置送出時被拒絕。
        public var isWrite: Bool {
            switch self {
            case .paneSendKeys: return true
            default: return false
            }
        }
    }
}

extension HostServiceProtocol {
    /// 主機服務送給 app 的訊息，以 type 區分。
    public enum ServerMessage: Codable, Sendable, Equatable {
        case welcome(Welcome)
        case agentsListResult(AgentsListResult)
        case paneSendKeysResult(PaneSendKeysResult)
        case eventsSubscribeResult(EventsSubscribeResult)
        case subscribedEvent(SubscribedEvent)
        case eventsEnded(EventsEnded)
        case eventsUnsubscribeResult(EventsUnsubscribeResult)
        case errorMessage(ErrorMessage)

        private enum TypeKey: String, CodingKey {
            case type
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TypeKey.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "welcome": self = .welcome(try Welcome(from: decoder))
            case "agents.list.result": self = .agentsListResult(try AgentsListResult(from: decoder))
            case "pane.send_keys.result": self = .paneSendKeysResult(try PaneSendKeysResult(from: decoder))
            case "events.subscribe.result": self = .eventsSubscribeResult(try EventsSubscribeResult(from: decoder))
            case "events.event": self = .subscribedEvent(try SubscribedEvent(from: decoder))
            case "events.ended": self = .eventsEnded(try EventsEnded(from: decoder))
            case "events.unsubscribe.result": self = .eventsUnsubscribeResult(try EventsUnsubscribeResult(from: decoder))
            case "error": self = .errorMessage(try ErrorMessage(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown message type \(type)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: TypeKey.self)
            switch self {
            case .welcome(let message):
                try container.encode("welcome", forKey: .type)
                try message.encode(to: encoder)
            case .agentsListResult(let message):
                try container.encode("agents.list.result", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendKeysResult(let message):
                try container.encode("pane.send_keys.result", forKey: .type)
                try message.encode(to: encoder)
            case .eventsSubscribeResult(let message):
                try container.encode("events.subscribe.result", forKey: .type)
                try message.encode(to: encoder)
            case .subscribedEvent(let message):
                try container.encode("events.event", forKey: .type)
                try message.encode(to: encoder)
            case .eventsEnded(let message):
                try container.encode("events.ended", forKey: .type)
                try message.encode(to: encoder)
            case .eventsUnsubscribeResult(let message):
                try container.encode("events.unsubscribe.result", forKey: .type)
                try message.encode(to: encoder)
            case .errorMessage(let message):
                try container.encode("error", forKey: .type)
                try message.encode(to: encoder)
            }
        }
    }
}

extension HostServiceProtocol {
    /// 握手：連線後第一個請求，帶 app 使用的協定版本。
    public struct Hello: Codable, Sendable, Equatable {
        /// 請求識別碼，回應帶回同一個值。
        public var requestId: String
        public var protocolVersion: Int
        /// app 版本，只用於診斷。
        public var appVersion: String?

        public init(requestId: String, protocolVersion: Int, appVersion: String? = nil) {
            self.requestId = requestId
            self.protocolVersion = protocolVersion
            self.appVersion = appVersion
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case protocolVersion = "protocol_version"
            case appVersion = "app_version"
        }
    }
}

extension HostServiceProtocol {
    /// 握手成功：主機服務的協定版本、版本，以及 herdr 伺服器 ping 回報的版本與能力。
    public struct Welcome: Codable, Sendable, Equatable {
        public var requestId: String
        public var protocolVersion: Int
        public var hostServiceVersion: String
        public var herdr: HerdrServer

        public init(requestId: String, protocolVersion: Int, hostServiceVersion: String, herdr: HerdrServer) {
            self.requestId = requestId
            self.protocolVersion = protocolVersion
            self.hostServiceVersion = hostServiceVersion
            self.herdr = herdr
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case protocolVersion = "protocol_version"
            case hostServiceVersion = "host_service_version"
            case herdr
        }
    }
}

extension HostServiceProtocol {
    /// herdr 伺服器(不是 CLI)的版本與能力。
    public struct HerdrServer: Codable, Sendable, Equatable {
        public var version: String
        public var `protocol`: Int
        /// ping 的 capabilities 裡值為 true 的名稱。
        public var capabilities: [String]

        public init(version: String, `protocol`: Int, capabilities: [String]) {
            self.version = version
            self.protocol = `protocol`
            self.capabilities = capabilities
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case `protocol`
            case capabilities
        }
    }
}

extension HostServiceProtocol {
    /// 取得 Agent 列表(herdr session.snapshot)。
    public struct AgentsList: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// Agent 列表與它們所在的 workspace。
    public struct AgentsListResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var workspaces: [Workspace]
        public var agents: [Agent]

        public init(requestId: String, workspaces: [Workspace], agents: [Agent]) {
            self.requestId = requestId
            self.workspaces = workspaces
            self.agents = agents
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case workspaces
            case agents
        }
    }
}

extension HostServiceProtocol {
    public struct Workspace: Codable, Sendable, Equatable {
        public var workspaceId: String
        public var label: String

        public init(workspaceId: String, label: String) {
            self.workspaceId = workspaceId
            self.label = label
        }

        private enum CodingKeys: String, CodingKey {
            case workspaceId = "workspace_id"
            case label
        }
    }
}

extension HostServiceProtocol {
    /// herdr 在某個 Pane 偵測到的 Agent。
    public struct Agent: Codable, Sendable, Equatable {
        public var paneId: String
        public var workspaceId: String
        public var tabId: String
        /// herdr 的 agent 名稱，例如 claude、codex。
        public var agent: String?
        public var status: AgentStatus
        /// 去掉狀態符號的終端機標題。
        public var title: String?
        public var cwd: String?
        public var session: AgentSession?

        public init(paneId: String, workspaceId: String, tabId: String, agent: String? = nil, status: AgentStatus, title: String? = nil, cwd: String? = nil, session: AgentSession? = nil) {
            self.paneId = paneId
            self.workspaceId = workspaceId
            self.tabId = tabId
            self.agent = agent
            self.status = status
            self.title = title
            self.cwd = cwd
            self.session = session
        }

        private enum CodingKeys: String, CodingKey {
            case paneId = "pane_id"
            case workspaceId = "workspace_id"
            case tabId = "tab_id"
            case agent
            case status
            case title
            case cwd
            case session
        }
    }
}

extension HostServiceProtocol {
    /// herdr 回報的 Agent 狀態。
    public enum AgentStatus: String, Codable, Sendable, CaseIterable {
        case idle
        case working
        case blocked
        case done
        case unknown
    }
}

extension HostServiceProtocol {
    /// herdr 的 agent_session:定位對話紀錄用。
    public struct AgentSession: Codable, Sendable, Equatable {
        public var source: String
        public var agent: String
        public var kind: String
        public var value: String

        public init(source: String, agent: String, kind: String, value: String) {
            self.source = source
            self.agent = agent
            self.kind = kind
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case source
            case agent
            case kind
            case value
        }
    }
}

extension HostServiceProtocol {
    /// 對 Pane 送出按鍵(herdr pane.send_keys)。
    public struct PaneSendKeys: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        /// herdr 鍵名，例如 enter、esc、ctrl+c。
        public var keys: [String]

        public init(requestId: String, paneId: String, keys: [String]) {
            self.requestId = requestId
            self.paneId = paneId
            self.keys = keys
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case keys
        }
    }
}

extension HostServiceProtocol {
    /// 按鍵已送到 Pane。
    public struct PaneSendKeysResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// 開一條 Agent 事件串流(herdr events.subscribe)。herdr 接受後回 events.subscribe.result,之後以 events.event 推送，直到 events.ended 或 events.unsubscribe。事件只是「該重讀了」的訊號，對帳用 agents.list。
    public struct EventsSubscribe: Codable, Sendable, Equatable {
        public var requestId: String
        /// 串流識別碼(app 自訂，同一條連線內不可重複);這條串流的訊息都帶它。
        public var streamId: String
        public var subscriptions: [EventSubscription]

        public init(requestId: String, streamId: String, subscriptions: [EventSubscription]) {
            self.requestId = requestId
            self.streamId = streamId
            self.subscriptions = subscriptions
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case subscriptions
        }
    }
}

extension HostServiceProtocol {
    /// 一筆 herdr 事件訂閱。herdr 不認得的事件或不存在的 Pane 會讓整個訂閱被拒(herdr_error)。
    public struct EventSubscription: Codable, Sendable, Equatable {
        /// herdr 的訂閱型別，例如 pane.agent_status_changed、workspace.created。
        public var event: String
        /// pane.agent_status_changed 必填;其他型別不帶。
        public var paneId: String?

        public init(event: String, paneId: String? = nil) {
            self.event = event
            self.paneId = paneId
        }

        private enum CodingKeys: String, CodingKey {
            case event
            case paneId = "pane_id"
        }
    }
}

extension HostServiceProtocol {
    /// herdr 接受了訂閱。此後的變化才會推送;之前的要靠 agents.list 對帳。
    public struct EventsSubscribeResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String

        public init(requestId: String, streamId: String) {
            self.requestId = requestId
            self.streamId = streamId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
        }
    }
}

extension HostServiceProtocol {
    /// herdr 推送的一個事件(沒有 request_id)。
    public struct SubscribedEvent: Codable, Sendable, Equatable {
        public var streamId: String
        /// herdr 事件的 wire 名稱，例如 pane_agent_status_changed。
        public var event: String
        /// 事件指名 Pane 時才有。
        public var paneId: String?

        public init(streamId: String, event: String, paneId: String? = nil) {
            self.streamId = streamId
            self.event = event
            self.paneId = paneId
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case event
            case paneId = "pane_id"
        }
    }
}

extension HostServiceProtocol {
    /// 事件串流在主機端結束(沒有 request_id)。有 code 表示失敗;herdr 的 events_lost 是 code herdr_error 加 herdr_code events_lost,app 重新訂閱並對帳。
    public struct EventsEnded: Codable, Sendable, Equatable {
        public var streamId: String
        public var code: ErrorCode?
        /// 給開發者看的說明。
        public var message: String?
        /// code 是 herdr_error 時，herdr 原本的錯誤碼。
        public var herdrCode: String?

        public init(streamId: String, code: ErrorCode? = nil, message: String? = nil, herdrCode: String? = nil) {
            self.streamId = streamId
            self.code = code
            self.message = message
            self.herdrCode = herdrCode
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case code
            case message
            case herdrCode = "herdr_code"
        }
    }
}

extension HostServiceProtocol {
    /// 關閉一條事件串流，主機服務關掉對應的 herdr 訂閱。不認得的串流識別碼也回成功。
    public struct EventsUnsubscribe: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String

        public init(requestId: String, streamId: String) {
            self.requestId = requestId
            self.streamId = streamId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
        }
    }
}

extension HostServiceProtocol {
    /// 事件串流已關閉，之後不再有這條串流的訊息。
    public struct EventsUnsubscribeResult: Codable, Sendable, Equatable {
        public var requestId: String

        public init(requestId: String) {
            self.requestId = requestId
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }
}

extension HostServiceProtocol {
    /// POST /v1/pair 的本文：以配對碼換裝置權杖。QR code 的內容是 purrdr://pair?address=<HTTPS 位址>&code=<配對碼>。
    public struct PairRequest: Codable, Sendable, Equatable {
        /// 大小寫與連字號不拘，例如 K7QM-2XPA。
        public var pairingCode: String
        /// 顯示在主機裝置列表的名稱。
        public var deviceName: String

        public init(pairingCode: String, deviceName: String) {
            self.pairingCode = pairingCode
            self.deviceName = deviceName
        }

        private enum CodingKeys: String, CodingKey {
            case pairingCode = "pairing_code"
            case deviceName = "device_name"
        }
    }
}

extension HostServiceProtocol {
    /// 配對成功。device_token 只在這裡出現一次，主機只存雜湊。
    public struct PairResponse: Codable, Sendable, Equatable {
        public var deviceId: String
        public var deviceToken: String
        /// 唯讀裝置的寫入類操作會被拒絕(read_only_device)。
        public var readOnly: Bool

        public init(deviceId: String, deviceToken: String, readOnly: Bool) {
            self.deviceId = deviceId
            self.deviceToken = deviceToken
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case deviceToken = "device_token"
            case readOnly = "read_only"
        }
    }
}

extension HostServiceProtocol {
    /// 請求失敗(WSS 訊息，也是配對與撤銷 HTTPS 請求失敗時的本文)。訊息本身無法解析時沒有 request_id。
    public struct ErrorMessage: Codable, Sendable, Equatable {
        public var requestId: String?
        public var code: ErrorCode
        /// 給開發者看的說明，不顯示給使用者。
        public var message: String
        /// code 是 herdr_error 時，herdr 原本的錯誤碼。
        public var herdrCode: String?
        /// code 是 protocol_version_unsupported 時，主機服務支援的協定版本。
        public var supportedProtocolVersions: [Int]?

        public init(requestId: String? = nil, code: ErrorCode, message: String, herdrCode: String? = nil, supportedProtocolVersions: [Int]? = nil) {
            self.requestId = requestId
            self.code = code
            self.message = message
            self.herdrCode = herdrCode
            self.supportedProtocolVersions = supportedProtocolVersions
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case code
            case message
            case herdrCode = "herdr_code"
            case supportedProtocolVersions = "supported_protocol_versions"
        }
    }
}

extension HostServiceProtocol {
    /// 錯誤種類。WSS 收到 device_token_invalid／device_token_revoked 後，主機服務以 close code 4401 關閉連線;HTTPS 請求回 401。
    public enum ErrorCode: String, Codable, Sendable, CaseIterable {
        case invalidMessage = "invalid_message"
        case handshakeRequired = "handshake_required"
        case protocolVersionUnsupported = "protocol_version_unsupported"
        case herdrUnavailable = "herdr_unavailable"
        case herdrCapabilityMissing = "herdr_capability_missing"
        case herdrError = "herdr_error"
        case deviceTokenInvalid = "device_token_invalid"
        case deviceTokenRevoked = "device_token_revoked"
        case readOnlyDevice = "read_only_device"
        case pairingCodeInvalid = "pairing_code_invalid"
        case pairingCodeExpired = "pairing_code_expired"
        case internalError = "internal_error"
    }
}
