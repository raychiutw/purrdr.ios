import Foundation
import PurrdrCore

/// 喚醒探測(行為規格 §7.5):app 在背景超過 60 秒後回前景，先在主機上跑一個無害指令(`true`),期限 3 秒。
///
/// 掛起期間死掉的連線在 3 秒內被發現並丟棄，接著的列表讀取在新連線上快速重撥，
/// 而不是每個請求各自等到自己的期限。探測只執行 `true`,所以丟棄連線不會讓任何寫入被重送。
public struct WakeProbe: Sendable {
    /// 無害指令。POSIX shell 與 PowerShell 都認得。
    public static let command = "true"
    /// 背景超過這麼久才探測。
    public static let backgroundThreshold: Duration = .seconds(60)
    public static let timeout: Duration = .seconds(3)

    private let channel: any HostChannel
    private let sleep: Sleep

    public init(channel: any HostChannel, sleep: @escaping Sleep = Sleeping.task) {
        self.channel = channel
        self.sleep = sleep
    }

    /// 連線活著回傳 `true`;期限到(含開通道卡住)或連線層錯誤時丟棄連線(下一個指令重新撥號)並回傳 `false`。
    @discardableResult
    public func run() async -> Bool {
        let alive = (try? await channel.runOnce(Self.command, deadline: Self.timeout, includesOpening: true, sleep: sleep) { session in
            // 有結束狀態就代表通道與連線都正常(exit code 不重要)。
            try await session.read().didExit
        }) ?? false
        if !alive { await channel.disconnect() }
        return alive
    }

    /// 預先撥號(#550):跑同一個無害指令讓通道重撥(期限 10 秒、含開通道);與 `run()` 不同,失敗不丟棄連線,
    /// 後面的請求自己會重試。
    public func dial() async {
        _ = try? await channel.runOnce(Self.command, deadline: HostCommandDeadline.probe, includesOpening: true, sleep: sleep) { session in
            try await session.read().didExit
        }
    }
}
