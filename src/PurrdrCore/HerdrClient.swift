import Foundation

/// 經主機通道呼叫 herdr socket API 的 client。
///
/// 每個請求開一個 `herdr remote-api-bridge`,把請求一行寫進 stdin,**不送 EOF**(bridge 在 EOF 時會放棄
/// 「需要等待」的請求),讀到第一行回應後由我方關閉通道(行為規格 §3.3)。
public struct HerdrClient: Sendable {
    private let channel: any HostChannel
    private let herdr: HerdrInstallation

    public init(channel: any HostChannel, herdr: HerdrInstallation = HerdrInstallation()) {
        self.channel = channel
        self.herdr = herdr
    }

    /// 讀主機目前的全量狀態(`session.snapshot`)。
    public func snapshot() async throws -> HostSnapshot {
        let result = try await request(method: "session.snapshot", as: SnapshotResult.self)
        return result.snapshot.hostSnapshot
    }

    /// 健康檢查：伺服器版本(行為規格 §3.4 `ping`)。
    public func ping() async throws -> String {
        try await request(method: "ping", as: PingResult.self).version
    }

    /// 主機上 herdr 的 agent 整合(`integration.list`)。
    public func integrations() async throws -> [AgentIntegration] {
        try await request(method: "integration.list", as: IntegrationListResult.self).integrations.map {
            AgentIntegration(
                target: $0.target, label: $0.label ?? $0.target,
                state: AgentIntegration.State(rawValue: $0.state ?? "") ?? .unknown, available: $0.available ?? false)
        }
    }

    private func request<Result: Decodable>(method: String, as: Result.Type) async throws -> Result {
        let session = try await channel.execute(HerdrCommand.bridge(herdr))
        let line: Data
        do {
            try await session.write(Data(#"{"id":"purrdr:\#(method)","method":"\#(method)","params":{}}"#.utf8) + [0x0A])
            line = try await Self.firstLine(of: session)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        return try Self.decode(line, as: Result.self)
    }

    /// 讀到 stdout 的第一行就停。stdout 沒有任何內容就結束時，帶上 exit code 與 stderr 回報。
    private static func firstLine(of session: any ExecSession) async throws -> Data {
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
        for try await event in session.output {
            switch event {
            case .stdout(let data):
                stdout.append(data)
                if let newline = stdout.firstIndex(of: 0x0A) { return stdout[stdout.startIndex..<newline] }
            case .stderr(let data):
                stderr.append(data)
            case .exit(let code, _):
                exitCode = code
            }
        }
        // herdr 失敗時可能把錯誤 envelope 印在 stderr(行為規格 §3.2)。
        if stdout.isEmpty, let envelope = stderr.split(separator: 0x0A).first(where: { $0.first == UInt8(ascii: "{") }) {
            return Data(envelope)
        }
        // bridge 連不到 socket = 這個 session 沒有在跑 herdr(行為規格 §3.3)。
        let stderrText = String(decoding: stderr, as: UTF8.self)
        if stdout.isEmpty, stderrText.contains("failed to connect to remote Herdr API socket") {
            throw HerdrError.herdr(code: "server_not_running", message: stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !stdout.isEmpty else {
            throw HerdrError.noResponse(exitCode: exitCode, stderr: String(decoding: stderr, as: UTF8.self))
        }
        return stdout
    }

    private static func decode<Result: Decodable>(_ line: Data, as: Result.Type) throws -> Result {
        let envelope: Envelope<Result>
        do {
            envelope = try JSONDecoder().decode(Envelope<Result>.self, from: line)
        } catch {
            throw HerdrError.malformedResponse
        }
        if let error = envelope.error { throw HerdrError.herdr(code: error.code, message: error.message) }
        guard let result = envelope.result else { throw HerdrError.malformedResponse }
        return result
    }
}

/// 呼叫 herdr 的錯誤。
public enum HerdrError: Error, Equatable {
    /// herdr 回了錯誤 envelope。未知的碼保留 herdr 原文(行為規格 §3.8)。
    case herdr(code: String, message: String)
    /// 指令結束時 stdout 沒有任何回應。
    case noResponse(exitCode: Int32?, stderr: String)
    /// 回應不是 herdr 的 JSON envelope。
    case malformedResponse
}

// MARK: - wire format(只在這裡處理 snake_case)

private struct Envelope<Result: Decodable>: Decodable {
    var result: Result?
    var error: WireError?
}

private struct WireError: Decodable {
    var code: String
    var message: String
}

private struct PingResult: Decodable {
    var version: String
}

private struct IntegrationListResult: Decodable {
    var integrations: [WireIntegration]
}

private struct WireIntegration: Decodable {
    var target: String
    var label: String?
    var available: Bool?
    var state: String?
}

private struct SnapshotResult: Decodable {
    var snapshot: WireSnapshot
}

private struct WireSnapshot: Decodable {
    var version: String
    var workspaces: [WireWorkspace]?
    var agents: [WireAgent]?

    var hostSnapshot: HostSnapshot {
        let labels = Dictionary((workspaces ?? []).map { ($0.workspaceID, $0.label) }, uniquingKeysWith: { first, _ in first })
        return HostSnapshot(version: version, agents: (agents ?? []).map { $0.agent(workspaceLabel: labels[$0.workspaceID] ?? nil) })
    }
}

private struct WireWorkspace: Decodable {
    var workspaceID: String
    var label: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
    }
}

private struct WireAgent: Decodable {
    var paneID: String
    var workspaceID: String
    var agent: String?
    var agentStatus: String?
    var name: String?
    var terminalTitleStripped: String?
    var cwd: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agent
        case agentStatus = "agent_status"
        case name
        case terminalTitleStripped = "terminal_title_stripped"
        case cwd
    }

    func agent(workspaceLabel: String?) -> Agent {
        Agent(
            paneID: paneID,
            workspaceID: workspaceID,
            kind: agent ?? "",
            status: agentStatus.flatMap(AgentStatus.init(rawValue:)) ?? .unknown,
            name: name.nonEmpty,
            terminalTitle: terminalTitleStripped.nonEmpty,
            workspaceLabel: workspaceLabel.nonEmpty,
            cwd: cwd.nonEmpty
        )
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
