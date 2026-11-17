// 由 protocol/host-service.schema.json 產生，不要手動修改。重新產生:cd host-service && cargo run -p protocol-codegen

import Foundation

/// 主機服務協定(ADR-0010)的訊息型別。
public enum HostServiceProtocol {
    /// 協定版本(schema 的 `x-protocol-version`)。
    public static let version = 1
}

extension HostServiceProtocol {
    /// app 送給主機服務的訊息，以 type 區分。
    public enum ClientMessage: Codable, Sendable, Equatable {
        case hello(Hello)
        case agentsList(AgentsList)

        private enum TypeKey: String, CodingKey {
            case type
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TypeKey.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "hello": self = .hello(try Hello(from: decoder))
            case "agents.list": self = .agentsList(try AgentsList(from: decoder))
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
            }
        }
    }
}

extension HostServiceProtocol {
    /// 主機服務送給 app 的訊息，以 type 區分。
    public enum ServerMessage: Codable, Sendable, Equatable {
        case welcome(Welcome)
        case agentsListResult(AgentsListResult)
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
    /// 請求失敗。訊息本身無法解析時沒有 request_id。
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
    /// 錯誤種類。
    public enum ErrorCode: String, Codable, Sendable, CaseIterable {
        case invalidMessage = "invalid_message"
        case handshakeRequired = "handshake_required"
        case protocolVersionUnsupported = "protocol_version_unsupported"
        case herdrUnavailable = "herdr_unavailable"
        case herdrCapabilityMissing = "herdr_capability_missing"
        case herdrError = "herdr_error"
    }
}
