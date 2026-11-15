import Foundation
import Observation
import PurrdrCore

/// Tailscale SSH check mode 的提示：主機要求重新驗證時顯示驗證網址(可一鍵開啟)與「取消」。
///
/// 主機通道經 `observer` 回報(在 event loop 上);這裡依回報順序轉到 main actor。驗證完成後通道自己繼續，
/// 等待中的指令自動接著跑，提示隨之收起。所有主機通道共用一個(同時只會有一個連線在等驗證)。
@MainActor
@Observable
public final class TailscaleCheckModel {
    /// 等待中的驗證;`nil` = 沒有在等。
    public private(set) var prompt: TailscaleCheckPrompt?

    /// 驗證網址。
    public var url: URL? { prompt?.url }

    @ObservationIgnored private let updates: AsyncStream<TailscaleCheckPrompt?>.Continuation
    @ObservationIgnored private var consumer: Task<Void, Never>?

    public init() {
        let (stream, continuation) = AsyncStream<TailscaleCheckPrompt?>.makeStream()
        updates = continuation
        consumer = Task { [weak self] in
            for await prompt in stream {
                self?.prompt = prompt
            }
        }
    }

    isolated deinit {
        updates.finish()
        consumer?.cancel()
    }

    /// 交給主機通道(`SSHHostChannel(tailscaleCheck:)`)的回報。
    public nonisolated var observer: TailscaleCheckObserver {
        { [updates] prompt in updates.yield(prompt) }
    }

    /// 不等了：收起提示，並請主機通道關掉這次連線(等待中的指令以「已取消」結束)。
    public func cancel() async {
        guard let prompt else { return }
        self.prompt = nil
        await prompt.cancel()
    }
}
