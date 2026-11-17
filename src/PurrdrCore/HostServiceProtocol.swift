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
        case paneTerminalOpen(PaneTerminalOpen)
        case paneTerminalInput(PaneTerminalInput)
        case paneTerminalResize(PaneTerminalResize)
        case paneTerminalScroll(PaneTerminalScroll)
        case paneTerminalClose(PaneTerminalClose)

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
            case "pane.terminal.open": self = .paneTerminalOpen(try PaneTerminalOpen(from: decoder))
            case "pane.terminal.input": self = .paneTerminalInput(try PaneTerminalInput(from: decoder))
            case "pane.terminal.resize": self = .paneTerminalResize(try PaneTerminalResize(from: decoder))
            case "pane.terminal.scroll": self = .paneTerminalScroll(try PaneTerminalScroll(from: decoder))
            case "pane.terminal.close": self = .paneTerminalClose(try PaneTerminalClose(from: decoder))
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
            case .paneTerminalOpen(let message):
                try container.encode("pane.terminal.open", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalInput(let message):
                try container.encode("pane.terminal.input", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalResize(let message):
                try container.encode("pane.terminal.resize", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalScroll(let message):
                try container.encode("pane.terminal.scroll", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalClose(let message):
                try container.encode("pane.terminal.close", forKey: .type)
                try message.encode(to: encoder)
            }
        }

        /// 寫入類訊息(schema 的 `x-write`);唯讀裝置送出時被拒絕。
        public var isWrite: Bool {
            switch self {
            case .paneSendKeys, .paneTerminalInput, .paneTerminalResize, .paneTerminalScroll: return true
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
        case paneTerminalOpenResult(PaneTerminalOpenResult)
        case paneTerminalFrame(PaneTerminalFrame)
        case paneTerminalClosed(PaneTerminalClosed)
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
            case "pane.terminal.open.result": self = .paneTerminalOpenResult(try PaneTerminalOpenResult(from: decoder))
            case "pane.terminal.frame": self = .paneTerminalFrame(try PaneTerminalFrame(from: decoder))
            case "pane.terminal.closed": self = .paneTerminalClosed(try PaneTerminalClosed(from: decoder))
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
            case .paneTerminalOpenResult(let message):
                try container.encode("pane.terminal.open.result", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalFrame(let message):
                try container.encode("pane.terminal.frame", forKey: .type)
                try message.encode(to: encoder)
            case .paneTerminalClosed(let message):
                try container.encode("pane.terminal.closed", forKey: .type)
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
    /// 開 Pane 終端機(ADR-0005):主機服務以子行程執行 herdr terminal session control;唯讀裝置改用 observe(只能看)。串流識別碼就是這個請求的 request_id。
    public struct PaneTerminalOpen: Codable, Sendable, Equatable {
        public var requestId: String
        /// pane id 或 terminal id。
        public var target: String
        public var columns: Int
        public var rows: Int
        /// 接管別人正在操作的 Pane(唯讀裝置忽略)。
        public var takeover: Bool?

        public init(requestId: String, target: String, columns: Int, rows: Int, takeover: Bool? = nil) {
            self.requestId = requestId
            self.target = target
            self.columns = columns
            self.rows = rows
            self.takeover = takeover
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case target
            case columns
            case rows
            case takeover
        }
    }
}

extension HostServiceProtocol {
    /// Pane 終端機已開啟;畫面更新接著以 pane.terminal.frame 送出，結束時送 pane.terminal.closed。
    public struct PaneTerminalOpenResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// 等於開啟請求的 request_id。
        public var streamId: String
        /// 唯讀裝置以 observe 接上：只能看，輸入會被拒絕。
        public var readOnly: Bool

        public init(requestId: String, streamId: String, readOnly: Bool) {
            self.requestId = requestId
            self.streamId = streamId
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case readOnly = "read_only"
        }
    }
}

extension HostServiceProtocol {
    /// 一次畫面更新:herdr terminal.frame 原樣轉接。
    public struct PaneTerminalFrame: Codable, Sendable, Equatable {
        public var streamId: String
        /// 每條連線從 1 起算。
        public var seq: Int
        public var width: Int
        public var height: Int
        /// true 是完整重繪。
        public var full: Bool
        /// ANSI 畫面 bytes 的標準 base64。
        public var bytes: String

        public init(streamId: String, seq: Int, width: Int, height: Int, full: Bool, bytes: String) {
            self.streamId = streamId
            self.seq = seq
            self.width = width
            self.height = height
            self.full = full
            self.bytes = bytes
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case seq
            case width
            case height
            case full
            case bytes
        }
    }
}

extension HostServiceProtocol {
    /// Pane 終端機結束，之後這個串流不再有訊息。
    public struct PaneTerminalClosed: Codable, Sendable, Equatable {
        public var streamId: String
        public var ending: PaneTerminalEnding
        /// ending 是 closed 時,herdr terminal.closed 的原文。
        public var reason: String?
        /// ending 是 failed 時,herdr 的 exit code。
        public var exitCode: Int?
        /// ending 是 failed 時,herdr 的 stderr(給開發者看)。
        public var message: String?

        public init(streamId: String, ending: PaneTerminalEnding, reason: String? = nil, exitCode: Int? = nil, message: String? = nil) {
            self.streamId = streamId
            self.ending = ending
            self.reason = reason
            self.exitCode = exitCode
            self.message = message
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case ending
            case reason
            case exitCode = "exit_code"
            case message
        }
    }
}

extension HostServiceProtocol {
    /// closed:herdr 送了 terminal.closed;disconnected:沒有 terminal.closed 就斷了(可重新連線);failed:herdr 沒跑起來。
    public enum PaneTerminalEnding: String, Codable, Sendable, CaseIterable {
        case closed
        case disconnected
        case failed
    }
}

extension HostServiceProtocol {
    /// Pane 終端機的鍵盤輸入(herdr terminal.input)。不回應;稽核只在開啟時記一筆，不記內容。
    public struct PaneTerminalInput: Codable, Sendable, Equatable {
        public var streamId: String
        /// 輸入 bytes 的標準 base64,每則不超過 64 KiB。
        public var bytes: String

        public init(streamId: String, bytes: String) {
            self.streamId = streamId
            self.bytes = bytes
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case bytes
        }
    }
}

extension HostServiceProtocol {
    /// 改變 viewport 格數(herdr terminal.resize)。不回應。
    public struct PaneTerminalResize: Codable, Sendable, Equatable {
        public var streamId: String
        public var columns: Int
        public var rows: Int

        public init(streamId: String, columns: Int, rows: Int) {
            self.streamId = streamId
            self.columns = columns
            self.rows = rows
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case columns
            case rows
        }
    }
}

extension HostServiceProtocol {
    /// 捲動(herdr terminal.scroll,source 固定 wheel)。不回應。
    public struct PaneTerminalScroll: Codable, Sendable, Equatable {
        public var streamId: String
        public var direction: TerminalScrollDirection
        public var lines: Int
        public var column: Int
        public var row: Int

        public init(streamId: String, direction: TerminalScrollDirection, lines: Int, column: Int, row: Int) {
            self.streamId = streamId
            self.direction = direction
            self.lines = lines
            self.column = column
            self.row = row
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case direction
            case lines
            case column
            case row
        }
    }
}

extension HostServiceProtocol {
    /// 捲動方向。
    public enum TerminalScrollDirection: String, Codable, Sendable, CaseIterable {
        case up
        case down
    }
}

extension HostServiceProtocol {
    /// 關閉 Pane 終端機:control 關閉 stdin(等同 release),observe 結束子行程。不回應。
    public struct PaneTerminalClose: Codable, Sendable, Equatable {
        public var streamId: String

        public init(streamId: String) {
            self.streamId = streamId
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
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
