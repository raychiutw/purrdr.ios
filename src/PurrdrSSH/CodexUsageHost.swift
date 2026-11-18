import Foundation
import PurrdrCore

/// 查不到 Codex 方案用量的原因。
public enum CodexUsageError: Error, Equatable {
    case unreadableResponse
}

/// Codex 的方案用量(#178):執行一次 `codex app-server`,讀 `account/rateLimits/read`。
public struct CodexUsageHost: Sendable {
    public static let command = "\(HerdrCommand.pathPrefix) codex app-server"

    private let channel: any HostChannel
    private let now: @Sendable () -> Date
    private let sleep: Sleep

    public init(channel: any HostChannel, now: @escaping @Sendable () -> Date = Date.init, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.now = now
        self.sleep = sleep
    }

    /// 查一次：`initialize` → `initialized` → `account/rateLimits/read`,讀到回應就關閉通道(子程序跟著結束)。
    public func readUsage() async throws -> PlanUsage {
        let capturedAt = now()
        return try await channel.runOnce(Self.command, deadline: HostCommandDeadline.standard, sleep: sleep) { session in
            var responses = AppServerResponses(session.output)
            try await session.write(Self.line(["method": "initialize", "id": 0, "params": Self.initializeParams]))
            _ = try await responses.result(for: 0)
            try await session.write(Self.line(["method": "initialized"]) + Self.line(["method": "account/rateLimits/read", "id": 1]))
            return try Self.planUsage(from: try await responses.result(for: 1), capturedAt: capturedAt)
        }
    }

    static var initializeParams: [String: Any] { ["clientInfo": ["name": "purrdr", "title": "Purrdr", "version": "1.0"]] }

    /// 一則 JSON-RPC 訊息(app-server 的 stdio 是一行一則，不帶 `jsonrpc` 欄位)。
    static func line(_ message: [String: Any]) -> Data {
        // 內容都是程式裡的固定值，序列化不會失敗。
        var data = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// 多 bucket 時用 Codex 本身的(`codex`);主要／次要依用量週期長度對應到 5 小時與每週，比例夾在 0～100。
    static func planUsage(from result: [String: Any], capturedAt: Date) throws -> PlanUsage {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let snapshot = (buckets?["codex"] ?? result["rateLimits"]) as? [String: Any] else {
            throw CodexUsageError.unreadableResponse
        }
        var periods: [PlanUsage.Period] = []
        for (key, slotKind) in [("primary", PlanUsage.Period.Kind.fiveHour), ("secondary", .week)] {
            guard let window = snapshot[key] as? [String: Any], let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let kind = (window["windowDurationMins"] as? NSNumber).map { $0.intValue < Self.dayMinutes ? .fiveHour : .week } ?? slotKind
            guard !periods.contains(where: { $0.kind == kind }) else { continue }
            let resetsAt = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            periods.append(PlanUsage.Period(kind: kind, usedPercentage: min(max(used, 0), 100), resetsAt: resetsAt))
        }
        return PlanUsage(periods: periods.sorted { $0.kind == .fiveHour && $1.kind == .week }, capturedAt: capturedAt)
    }

    /// 短於一天的用量週期算 5 小時，其餘算每週。
    static let dayMinutes = 24 * 60
}

/// app-server 的 stdout:一行一則 JSON,通知與其他回應略過，只取指定 `id` 的回應。
private struct AppServerResponses {
    private var events: AsyncThrowingStream<ExecOutput, any Error>.AsyncIterator
    private var buffer = Data()

    init(_ output: AsyncThrowingStream<ExecOutput, any Error>) {
        events = output.makeAsyncIterator()
    }

    mutating func result(for id: Int) async throws -> [String: Any] {
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (message["id"] as? NSNumber)?.intValue == id else { continue }
                guard let result = message["result"] as? [String: Any] else { throw CodexUsageError.unreadableResponse }
                return result
            }
            switch try await events.next() {
            case .stdout(let data)?: buffer.append(data)
            case .stderr?, .exit?: continue
            case nil: throw CodexUsageError.unreadableResponse
            }
        }
    }
}
