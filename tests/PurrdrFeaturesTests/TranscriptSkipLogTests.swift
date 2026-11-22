import Foundation
import PurrdrCore
import Testing
@testable import PurrdrFeatures

@Suite("對話紀錄略過行的診斷紀錄")
struct TranscriptSkipLogTests {
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ line: String) { lock.withLock { items.append(line) } }
        var all: [String] { lock.withLock { items } }
    }

    @Test("同一方言的同一種類只記一次,內容只有方言、種類與行數")
    func reportsEachUnknownKindOnce() {
        let lines = Lines()
        let log = TranscriptSkipLog(write: lines.add)
        var skips = TranscriptSkips()
        skips.unknownKinds["FUTURE_KIND_9"] = 3

        log.report(.antigravity, skips)
        log.report(.antigravity, skips)
        log.report(.codex, skips)

        #expect(lines.all.count == 2)
        #expect(lines.all[0].contains("antigravity") && lines.all[0].contains("FUTURE_KIND_9") && lines.all[0].contains("3"))
    }

    @Test("單獨一行解析不了(視窗邊界)不記")
    func ignoresSingleTruncatedLine() {
        let lines = Lines()
        var skips = TranscriptSkips()
        skips.unparsableLines = 1

        TranscriptSkipLog(write: lines.add).report(.claude, skips)

        #expect(lines.all.isEmpty)
    }
}
