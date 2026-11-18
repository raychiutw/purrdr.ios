import Foundation
import PurrdrCore
import PurrdrSSH

/// Demo 主機的 `codex app-server`(#178):回答 `initialize` 與 `account/rateLimits/read`,其餘請求不回。
actor DemoCodexAppServer: ExecSession {
    nonisolated let output: AsyncThrowingStream<ExecOutput, any Error>
    private let continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation
    private var stdin = Data()

    init() {
        (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
    }

    func write(_ data: Data) async throws {
        stdin.append(data)
        while let line = JSONLines.takeLine(from: &stdin) {
            guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = request["id"] as? Int,
                  let reply = Self.reply(to: request["method"] as? String, id: id, now: Date()) else { continue }
            continuation.yield(.stdout(Data((reply + "\n").utf8)))
        }
    }

    func closeStdin() async {
        continuation.yield(.exit(code: 0))
        continuation.finish()
    }

    func close() async { continuation.finish() }

    /// 範例用量：5 小時用了 24%、3 小時 40 分後重置;每週用了 47%、5 天後重置。
    static func reply(to method: String?, id: Int, now: Date) -> String? {
        let nowSeconds = Int(now.timeIntervalSince1970)
        switch method {
        case "initialize":
            return #"{"id":\#(id),"result":{"userAgent":"codex_cli_rs/demo"}}"#
        case "account/rateLimits/read":
            return #"""
                {"id":\#(id),"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":24,"windowDurationMins":300,"resetsAt":\#(nowSeconds + 3 * 3600 + 40 * 60)},"secondary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":\#(nowSeconds + 5 * 86400)},"planType":"plus"}}}
                """#
        default:
            return nil
        }
    }
}
