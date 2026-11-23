import Foundation
import PurrdrCore

/// 對話紀錄的解析(#498):JSONL 解碼與 metadata／進度更新是純計算，放在背景(`@concurrent`)做，
/// 大量輸出(#130 一次 64 KiB 以上)不卡畫面。結果回主執行緒交給對話時間軸增量套用(#480:不再整份重建列表)。
enum TranscriptProcessing {
    struct Prepared: Sendable {
        var messages: [TranscriptMessage]
        var skips: TranscriptSkips
        var metadata: TranscriptMetadata
        var progress: AgentProgress
    }

    /// 解析接在後面的一段:訊息(依 id 去重)、略過統計，並把每一行併進 metadata 與進度。
    @concurrent
    static func prepareAppended(
        lines: [String], dialect: TranscriptDialect, metadata: TranscriptMetadata, progress: AgentProgress,
        probe: (@Sendable () -> Void)?
    ) async -> Prepared {
        probe?()
        var metadata = metadata
        var progress = progress
        let (messages, skips) = parse(lines, dialect: dialect)
        for line in lines {
            dialect.updateMetadata(&metadata, with: line)
            progress.update(with: line, dialect: dialect)
        }
        return Prepared(messages: messages, skips: skips, metadata: metadata, progress: progress)
    }

    /// 解析開啟視窗的內容:metadata 與進度取視窗內最新的。
    @concurrent
    static func prepareWindow(lines: [String], dialect: TranscriptDialect, probe: (@Sendable () -> Void)?) async -> Prepared {
        probe?()
        let (messages, skips) = parse(lines, dialect: dialect)
        return Prepared(
            messages: messages, skips: skips, metadata: dialect.latestMetadata(in: lines),
            progress: AgentProgress.latest(in: lines, dialect: dialect))
    }

    /// 解析往上翻的一頁(只要訊息)。
    @concurrent
    static func prepareOlder(lines: [String], dialect: TranscriptDialect, probe: (@Sendable () -> Void)?) async
        -> (messages: [TranscriptMessage], skips: TranscriptSkips)
    {
        probe?()
        return parse(lines, dialect: dialect)
    }

    private static func parse(_ lines: [String], dialect: TranscriptDialect) -> (messages: [TranscriptMessage], skips: TranscriptSkips) {
        var seen = Set<String>()
        let parsed = dialect.parse(lines)
        return (parsed.messages.filter { seen.insert($0.id).inserted }, parsed.skips)
    }
}

/// 套用對話紀錄的先進先出鎖(#498):解析在背景做，等待期間主執行緒可以重入，
/// 多段內容(追蹤推送、往上翻、重讀視窗)仍照到達順序套用。
@MainActor
final class TranscriptApplyGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ body: () async -> Void) async {
        if isHeld {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isHeld = true
        }
        await body()
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
