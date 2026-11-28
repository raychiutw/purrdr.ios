import Foundation
import PurrdrCore

/// 連上主機後在背景把列表前幾個聊天讀進本機快取(#663,比照 Heeler):之後點進聊天時快取已是新的,馬上顯示。
///
/// 節制流量:
/// - 數量有上限(`limit`);行動網路下用更小的 `cellularLimit`(預設 0,不預讀)。
/// - 有變化才讀:每個聊天記下上次成功預讀時的 `signature`(session + Agent 狀態),沒變就不再讀。
/// - 一次只讀一個聊天(不並行),被取消(列表離開、進背景)就停在下一個之前;前景正在看的聊天(`isBlocked`)不預讀,
///   所以前景讀取永遠優先。
/// - 讀取量與點進聊天的開啟讀取相同(`TranscriptFeed.read`)。
@MainActor
package final class ConversationPrefetcher {
    package struct Candidate: Equatable, Sendable {
        package var route: ChatRoute
        package var target: TranscriptTarget
        /// 內容可能有變化的指紋(例如 session + 狀態);與上次成功預讀時相同就不再讀。
        package var signature: String

        package init(route: ChatRoute, target: TranscriptTarget, signature: String) {
            self.route = route
            self.target = target
            self.signature = signature
        }
    }

    private let limit: Int
    private let cellularLimit: Int
    private let isCellular: @MainActor () -> Bool
    private let isBlocked: @MainActor (ChatRoute) -> Bool
    private let read: @MainActor (Candidate) async -> Bool
    private var done: [ChatRoute: String] = [:]

    package init(
        limit: Int = 4, cellularLimit: Int = 0, isCellular: @escaping @MainActor () -> Bool = { false },
        isBlocked: @escaping @MainActor (ChatRoute) -> Bool = { _ in false },
        read: @escaping @MainActor (Candidate) async -> Bool
    ) {
        self.limit = limit
        self.cellularLimit = cellularLimit
        self.isCellular = isCellular
        self.isBlocked = isBlocked
        self.read = read
    }

    /// 依序預讀這些聊天(只取上限內的前幾個);被取消就停。
    package func prefetch(_ candidates: [Candidate]) async {
        for candidate in candidates.prefix(isCellular() ? cellularLimit : limit) {
            if Task.isCancelled { return }
            // 上限在每一個之前重新判斷:預讀途中換到行動網路就停。
            if isCellular(), cellularLimit <= 0 { return }
            guard done[candidate.route] != candidate.signature, !isBlocked(candidate.route) else { continue }
            if await read(candidate) { done[candidate.route] = candidate.signature }
        }
    }

    /// 主機被刪除或改了連線:忘掉那台主機的預讀紀錄。
    package func forget(host: HostSelection) {
        done = done.filter { $0.key.host != host }
    }

    /// 讀一個聊天的開啟視窗並寫進(已加主機範圍的)快取;不開追蹤。回傳是否讀成功(含不值得存的尾端:下次有變化再試)。
    /// 沒有可讀訊息的尾端不寫(#473):不會蓋掉原本可用的快取。
    package static func read(
        _ candidate: Candidate, reader: TranscriptReader, cache: any ConversationCache,
        limits: TranscriptReadLimits = .conservative
    ) async -> Bool {
        let feed = TranscriptFeed(
            reader: reader, cache: cache, chatKey: candidate.route.paneID, knownSessionID: candidate.target.sessionKey, clock: ConversationClock(),
            readLimits: { limits }, pageLines: 200, timings: nil, onSkips: nil)
        _ = await feed.bind(to: candidate.target)
        let result = await feed.read(candidate.target, savesCache: false)
        defer { feed.unbind(keepingDisplay: false) }
        guard result == .caughtUp, let snapshot = feed.cacheSnapshot() else { return false }
        guard TranscriptFeed.isWorthRestoring(snapshot), !snapshot.messages.isEmpty else { return false }
        await feed.saveCache()
        return true
    }
}
