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
        case transcriptLocate(TranscriptLocate)
        case transcriptWindow(TranscriptWindow)
        case transcriptFollow(TranscriptFollow)
        case transcriptUnfollow(TranscriptUnfollow)
        case paneSendText(PaneSendText)
        case agentPrompt(AgentPrompt)
        case eventsSubscribe(EventsSubscribe)
        case eventsUnsubscribe(EventsUnsubscribe)
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
            case "transcript.locate": self = .transcriptLocate(try TranscriptLocate(from: decoder))
            case "transcript.window": self = .transcriptWindow(try TranscriptWindow(from: decoder))
            case "transcript.follow": self = .transcriptFollow(try TranscriptFollow(from: decoder))
            case "transcript.unfollow": self = .transcriptUnfollow(try TranscriptUnfollow(from: decoder))
            case "pane.send_text": self = .paneSendText(try PaneSendText(from: decoder))
            case "agent.prompt": self = .agentPrompt(try AgentPrompt(from: decoder))
            case "events.subscribe": self = .eventsSubscribe(try EventsSubscribe(from: decoder))
            case "events.unsubscribe": self = .eventsUnsubscribe(try EventsUnsubscribe(from: decoder))
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
            case .transcriptLocate(let message):
                try container.encode("transcript.locate", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptWindow(let message):
                try container.encode("transcript.window", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptFollow(let message):
                try container.encode("transcript.follow", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptUnfollow(let message):
                try container.encode("transcript.unfollow", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendText(let message):
                try container.encode("pane.send_text", forKey: .type)
                try message.encode(to: encoder)
            case .agentPrompt(let message):
                try container.encode("agent.prompt", forKey: .type)
                try message.encode(to: encoder)
            case .eventsSubscribe(let message):
                try container.encode("events.subscribe", forKey: .type)
                try message.encode(to: encoder)
            case .eventsUnsubscribe(let message):
                try container.encode("events.unsubscribe", forKey: .type)
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
            case .paneSendKeys, .paneSendText, .agentPrompt, .paneTerminalInput, .paneTerminalResize, .paneTerminalScroll: return true
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
        case transcriptLocateResult(TranscriptLocateResult)
        case transcriptWindowResult(TranscriptWindowResult)
        case transcriptFollowResult(TranscriptFollowResult)
        case transcriptUpdate(TranscriptUpdate)
        case transcriptUnfollowResult(TranscriptUnfollowResult)
        case paneSendTextResult(PaneSendTextResult)
        case agentPromptResult(AgentPromptResult)
        case eventsSubscribeResult(EventsSubscribeResult)
        case subscribedEvent(SubscribedEvent)
        case eventsEnded(EventsEnded)
        case eventsUnsubscribeResult(EventsUnsubscribeResult)
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
            case "transcript.locate.result": self = .transcriptLocateResult(try TranscriptLocateResult(from: decoder))
            case "transcript.window.result": self = .transcriptWindowResult(try TranscriptWindowResult(from: decoder))
            case "transcript.follow.result": self = .transcriptFollowResult(try TranscriptFollowResult(from: decoder))
            case "transcript.update": self = .transcriptUpdate(try TranscriptUpdate(from: decoder))
            case "transcript.unfollow.result": self = .transcriptUnfollowResult(try TranscriptUnfollowResult(from: decoder))
            case "pane.send_text.result": self = .paneSendTextResult(try PaneSendTextResult(from: decoder))
            case "agent.prompt.result": self = .agentPromptResult(try AgentPromptResult(from: decoder))
            case "events.subscribe.result": self = .eventsSubscribeResult(try EventsSubscribeResult(from: decoder))
            case "events.event": self = .subscribedEvent(try SubscribedEvent(from: decoder))
            case "events.ended": self = .eventsEnded(try EventsEnded(from: decoder))
            case "events.unsubscribe.result": self = .eventsUnsubscribeResult(try EventsUnsubscribeResult(from: decoder))
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
            case .transcriptLocateResult(let message):
                try container.encode("transcript.locate.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptWindowResult(let message):
                try container.encode("transcript.window.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptFollowResult(let message):
                try container.encode("transcript.follow.result", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptUpdate(let message):
                try container.encode("transcript.update", forKey: .type)
                try message.encode(to: encoder)
            case .transcriptUnfollowResult(let message):
                try container.encode("transcript.unfollow.result", forKey: .type)
                try message.encode(to: encoder)
            case .paneSendTextResult(let message):
                try container.encode("pane.send_text.result", forKey: .type)
                try message.encode(to: encoder)
            case .agentPromptResult(let message):
                try container.encode("agent.prompt.result", forKey: .type)
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
    /// 握手成功：主機服務的協定版本、版本，herdr 伺服器 ping 回報的版本與能力，以及這支裝置是否唯讀。
    public struct Welcome: Codable, Sendable, Equatable {
        public var requestId: String
        public var protocolVersion: Int
        public var hostServiceVersion: String
        public var herdr: HerdrServer
        /// 這支裝置配對成唯讀：寫入類操作會被拒絕(read_only_device),app 停用輸入。
        public var readOnly: Bool

        public init(requestId: String, protocolVersion: Int, hostServiceVersion: String, herdr: HerdrServer, readOnly: Bool) {
            self.requestId = requestId
            self.protocolVersion = protocolVersion
            self.hostServiceVersion = hostServiceVersion
            self.herdr = herdr
            self.readOnly = readOnly
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case protocolVersion = "protocol_version"
            case hostServiceVersion = "host_service_version"
            case herdr
            case readOnly = "read_only"
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
    /// 定位對話紀錄(#59)。session 必須是 herdr snapshot 目前某個 Agent 的 agent_session;格式與 cwd 由主機服務從 snapshot 取得，app 不能指定路徑。
    public struct TranscriptLocate: Codable, Sendable, Equatable {
        public var requestId: String
        public var session: SessionReference
        /// 是否一併回傳檔案前兩行(Codex、Pi／OMP 的 header 檢查)。
        public var header: Bool

        public init(requestId: String, session: SessionReference, header: Bool) {
            self.requestId = requestId
            self.session = session
            self.header = header
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case session
            case header
        }
    }
}

extension HostServiceProtocol {
    /// herdr agent_session 的 kind 與 value。
    public struct SessionReference: Codable, Sendable, Equatable {
        /// id 或 path。
        public var kind: String
        public var value: String

        public init(kind: String, value: String) {
            self.kind = kind
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case value
        }
    }
}

extension HostServiceProtocol {
    /// 對話紀錄的路徑與大小(byte)。之後這條連線才能以這個路徑讀視窗與追蹤。
    public struct TranscriptLocateResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        public var size: Int
        /// 請求 header 時，檔案前兩行(原樣)。
        public var header: [String]?

        public init(requestId: String, path: String, size: Int, header: [String]? = nil) {
            self.requestId = requestId
            self.path = path
            self.size = size
            self.header = header
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case size
            case header
        }
    }
}

extension HostServiceProtocol {
    /// 讀以 end 為終點的最後 lines 行完整的行(開啟與往上翻頁)。path 必須是這條連線定位過的。
    public struct TranscriptWindow: Codable, Sendable, Equatable {
        public var requestId: String
        public var path: String
        public var end: Int
        public var lines: Int

        public init(requestId: String, path: String, end: Int, lines: Int) {
            self.requestId = requestId
            self.path = path
            self.end = end
            self.lines = lines
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case path
            case end
            case lines
        }
    }
}

extension HostServiceProtocol {
    /// 視窗的 byte 範圍與範圍內的行。
    public struct TranscriptWindowResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var start: Int
        public var end: Int
        public var records: [TranscriptRecord]

        public init(requestId: String, start: Int, end: Int, records: [TranscriptRecord]) {
            self.requestId = requestId
            self.start = start
            self.end = end
            self.records = records
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case start
            case end
            case records
        }
    }
}

extension HostServiceProtocol {
    /// 對話紀錄的一行：原始 byte 長度(不含換行)與剝除圖片後的內容(行為規格 R-B04、R-B06)。
    public struct TranscriptRecord: Codable, Sendable, Equatable {
        public var length: Int
        public var text: String

        public init(length: Int, text: String) {
            self.length = length
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case length
            case text
        }
    }
}

extension HostServiceProtocol {
    /// 開始追蹤對話紀錄尾端：從 from 起，主機服務把新增的完整行以 transcript.update 推送，直到 transcript.unfollow、追蹤結束或連線關閉。stream_id 由 app 指定，同一條連線內不可重複。path 必須是這條連線定位過的。
    public struct TranscriptFollow: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String
        public var path: String
        public var from: Int
        /// 一次落後超過這麼多 byte 就結束追蹤(too_far_behind),由 app 改讀視窗。
        public var limit: Int

        public init(requestId: String, streamId: String, path: String, from: Int, limit: Int) {
            self.requestId = requestId
            self.streamId = streamId
            self.path = path
            self.from = from
            self.limit = limit
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case path
            case from
            case limit
        }
    }
}

extension HostServiceProtocol {
    /// 追蹤開始，帶目前的大小與 from 之後已有的完整行;ended 有值時主機服務沒有開始追蹤。
    public struct TranscriptFollowResult: Codable, Sendable, Equatable {
        public var requestId: String
        public var streamId: String
        public var size: Int
        /// records 第一行的位置(byte)。
        public var start: Int
        public var records: [TranscriptRecord]
        public var ended: TranscriptStreamEnd?

        public init(requestId: String, streamId: String, size: Int, start: Int, records: [TranscriptRecord], ended: TranscriptStreamEnd? = nil) {
            self.requestId = requestId
            self.streamId = streamId
            self.size = size
            self.start = start
            self.records = records
            self.ended = ended
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case streamId = "stream_id"
            case size
            case start
            case records
            case ended
        }
    }
}

extension HostServiceProtocol {
    /// 追蹤中的對話紀錄有了新的完整行，或追蹤結束(ended)。主機服務主動推送，沒有 request_id。
    public struct TranscriptUpdate: Codable, Sendable, Equatable {
        public var streamId: String
        public var size: Int
        /// records 第一行的位置(byte)。
        public var start: Int
        public var records: [TranscriptRecord]
        public var ended: TranscriptStreamEnd?

        public init(streamId: String, size: Int, start: Int, records: [TranscriptRecord], ended: TranscriptStreamEnd? = nil) {
            self.streamId = streamId
            self.size = size
            self.start = start
            self.records = records
            self.ended = ended
        }

        private enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case size
            case start
            case records
            case ended
        }
    }
}

extension HostServiceProtocol {
    /// 主機服務停止追蹤的原因:shrank 檔案變小(換新)、too_far_behind 落後超過 limit、absent 檔案不見了、unreadable 讀不到。
    public enum TranscriptStreamEnd: String, Codable, Sendable, CaseIterable {
        case shrank
        case tooFarBehind = "too_far_behind"
        case absent
        case unreadable
    }
}

extension HostServiceProtocol {
    /// 停止追蹤(對話關閉)。
    public struct TranscriptUnfollow: Codable, Sendable, Equatable {
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
    /// 已停止追蹤;之後不再推送這個 stream_id。
    public struct TranscriptUnfollowResult: Codable, Sendable, Equatable {
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
    /// 對 Pane 送出文字(herdr pane.send_text),不補 Enter。
    public struct PaneSendText: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var text: String

        public init(requestId: String, paneId: String, text: String) {
            self.requestId = requestId
            self.paneId = paneId
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case text
        }
    }
}

extension HostServiceProtocol {
    /// 文字已送到 Pane。
    public struct PaneSendTextResult: Codable, Sendable, Equatable {
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
    /// 對 Agent 送出 prompt(herdr agent.prompt,target 是 pane_id)。
    public struct AgentPrompt: Codable, Sendable, Equatable {
        public var requestId: String
        public var paneId: String
        public var text: String
        public var wait: PromptWait?

        public init(requestId: String, paneId: String, text: String, wait: PromptWait? = nil) {
            self.requestId = requestId
            self.paneId = paneId
            self.text = text
            self.wait = wait
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case paneId = "pane_id"
            case text
            case wait
        }
    }
}

extension HostServiceProtocol {
    /// herdr agent.prompt 的 wait:等 Agent 進入其中一個狀態;主機服務等 herdr 的時間隨 timeout_ms 延長。
    public struct PromptWait: Codable, Sendable, Equatable {
        public var until: [AgentStatus]
        public var timeoutMs: Int

        public init(until: [AgentStatus], timeoutMs: Int) {
            self.until = until
            self.timeoutMs = timeoutMs
        }

        private enum CodingKeys: String, CodingKey {
            case until
            case timeoutMs = "timeout_ms"
        }
    }
}

extension HostServiceProtocol {
    /// herdr 收下 prompt。等待逾時、Agent 在等回答等情況以 herdr_error 回報(herdr_code 如 timeout、agent_blocked)。
    public struct AgentPromptResult: Codable, Sendable, Equatable {
        public var requestId: String
        /// herdr 回報的送達方式(例如 written_to_pty);沒有時省略。
        public var delivery: String?

        public init(requestId: String, delivery: String? = nil) {
            self.requestId = requestId
            self.delivery = delivery
        }

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case delivery
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
    /// 錯誤種類。WSS 收到 device_token_invalid／device_token_revoked 後，主機服務以 close code 4401 關閉連線;HTTPS 請求回 401。transcript_not_allowed:session 不是 herdr 目前回報的，或路徑不是這條連線定位過的;transcript_unsupported:這種 agent 的對話紀錄主機服務還讀不了;其他 transcript_* 對應行為規格 §4.7 的缺席、不可讀、有歧義、已壓縮。
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
        case transcriptNotAllowed = "transcript_not_allowed"
        case transcriptUnsupported = "transcript_unsupported"
        case transcriptAbsent = "transcript_absent"
        case transcriptUnreadable = "transcript_unreadable"
        case transcriptAmbiguous = "transcript_ambiguous"
        case transcriptCompressed = "transcript_compressed"
        case internalError = "internal_error"
    }
}
