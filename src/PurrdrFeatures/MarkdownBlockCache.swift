import Foundation
import PurrdrCore

/// 訊息 Markdown 解析結果的快取(#498):以訊息 id 為 key，內容(版本)不同就重新解析。
///
/// `AgentMessageView.body` 每次重算都解析一次(含主機路徑辨識)，捲動、trait 變化與父層失效時每列都做;
/// 同一則訊息內容沒變時直接用上次的結果。只在主執行緒使用。
@MainActor
final class MarkdownBlockCache {
    static let shared = MarkdownBlockCache()

    private struct Entry {
        var markdown: String
        var blocks: [MarkdownBlock]
        var lastUsed: Int
    }

    private let limit: Int
    private let parse: (String) -> [MarkdownBlock]
    private var entries: [String: Entry] = [:]
    private var tick = 0
    private(set) var parseCount = 0

    init(limit: Int = 600, parse: @escaping (String) -> [MarkdownBlock] = { Markdown.parse($0) }) {
        self.limit = limit
        self.parse = parse
    }

    func blocks(id: String, markdown: String) -> [MarkdownBlock] {
        tick += 1
        if var entry = entries[id], entry.markdown == markdown {
            entry.lastUsed = tick
            entries[id] = entry
            return entry.blocks
        }
        parseCount += 1
        let blocks = parse(markdown)
        entries[id] = Entry(markdown: markdown, blocks: blocks, lastUsed: tick)
        if entries.count > limit {
            // 最久沒用的先丟(一次丟四分之一，不必每次都排序)。
            let dropped = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(max(1, limit / 4)).map(\.key)
            for key in dropped { entries[key] = nil }
        }
        return blocks
    }
}
