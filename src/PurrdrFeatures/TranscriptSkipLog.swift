import Foundation
import PurrdrCore
import Synchronization
import os

/// 對話紀錄解析略過認不得的行時的診斷紀錄(#449、ADR-0013):`os.Logger` category `agent-profile`。
/// 只記方言名稱、種類名稱與行數,不含對話原文。同一方言的同一種類只記一次(每次輪詢都重解析,不洗版);
/// 單獨一行解析不了多半是視窗邊界切斷的第一行,不記。
final class TranscriptSkipLog: Sendable {
    static let shared = TranscriptSkipLog { message in
        Logger(subsystem: "com.raychiu.purrdr", category: "agent-profile").notice("\(message, privacy: .private)")
    }

    private let write: @Sendable (String) -> Void
    private let reported = Mutex<Set<String>>([])

    init(write: @escaping @Sendable (String) -> Void) { self.write = write }

    func report(_ dialect: TranscriptDialect, _ skips: TranscriptSkips) {
        for (kind, count) in skips.unknownKinds.sorted(by: { $0.key < $1.key }) {
            let key = "\(dialect.name)/\(kind)"
            let isNew = reported.withLock { $0.insert(key).inserted }
            if isNew { write("對話紀錄略過認不得的行:方言 \(dialect.name),種類 \(kind),\(count) 行") }
        }
        if skips.unparsableLines > 1 {
            let key = "\(dialect.name)/unparsable"
            let isNew = reported.withLock { $0.insert(key).inserted }
            if isNew { write("對話紀錄略過解析不了的行:方言 \(dialect.name),\(skips.unparsableLines) 行") }
        }
    }
}
