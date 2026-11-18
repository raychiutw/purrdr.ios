import Foundation
import Synchronization

/// 對話紀錄追蹤的一則事件(`HostConnection.followTranscript`)。
public enum TranscriptFollowEvent: Sendable, Equatable {
    /// 游標之後新增的完整行;下一則從 `chunk.end` 接著。
    case appended(TranscriptChunk)
    /// 游標之後接不上(檔案被換掉或變短，或這個連線方式落後太多無法接著讀):呼叫端重讀視窗。追蹤隨之結束。
    case replaced(size: Int)
}

/// 追蹤的節奏：兩次讀取之間等多久，以及立刻再讀一次。只有內部輪詢的連線方式(SSH)用;推送的(HTTPS)不看。
public final class TranscriptFollowPace: Sendable {
    private let currentInterval: Mutex<Duration>
    private let signal: WakeSignal

    public init(interval: Duration, sleep: @escaping Sleep = Sleeping.task) {
        currentInterval = Mutex(interval)
        signal = WakeSignal(sleep: sleep)
    }

    /// 兩次讀取之間的間隔;改了從下一次等待起生效。
    public var interval: Duration {
        get { currentInterval.withLock { $0 } }
        set { currentInterval.withLock { $0 = newValue } }
    }

    /// 立刻再讀一次(例如 Agent 狀態變了)。沒有人在等時，下一次等待直接結束。
    public func wake() {
        signal.wake()
    }

    /// 等到下一次讀取：間隔到，或被叫醒。取消或 `sleep` 失敗時丟出。
    public func wait() async throws {
        try await signal.wait(atMost: interval)
    }
}

extension HostConnection {
    /// 內部輪詢的追蹤(SSH 等每次都向主機讀的連線方式):每隔 `pace` 從游標分段接著讀一次(#130 的 `catchUp`),
    /// 有新增才送事件。取消或 `pace` 的等待失敗時安靜結束;讀取失敗以錯誤結束。
    public func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        TranscriptPolling.follow(connection: self, path: path, from: cursor, pace: pace)
    }
}

/// `followTranscript` 的預設實作：在內部以既有的分段接著讀輪詢。
package enum TranscriptPolling {
    package static func follow(
        connection: any HostConnection, path: String, from cursor: Int, pace: TranscriptFollowPace
    ) -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<TranscriptFollowEvent, any Error>.makeStream()
        let polling = Task {
            let reader = TranscriptReader(connection: connection)
            var follow = TranscriptFollow(cursor: cursor, isLive: true)
            do {
                while true {
                    try await pace.wait()
                    let read = try await reader.follow(path: path, follow)
                    follow = read.next
                    switch read.tail {
                    case .unchanged:
                        continue
                    case .appended(let chunk):
                        continuation.yield(.appended(chunk))
                    case .tooFarBehind(let size), .shrank(let size):
                        continuation.yield(.replaced(size: size))
                        continuation.finish()
                        return
                    }
                }
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in polling.cancel() }
        return events
    }
}
