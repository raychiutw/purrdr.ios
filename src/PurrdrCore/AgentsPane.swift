import Foundation

/// Claude Code 畫面底部的背景 agents 窗格(行為規格 §4.8)。
public struct AgentsPane: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: Int
        public var state: DelegationStatus
        /// `general-purpose`、`fork`、自訂類型名。
        public var kind: String
        public var task: String
        public var elapsedSeconds: Int
        public var tokens: Int?

        public init(id: Int, state: DelegationStatus, kind: String, task: String, elapsedSeconds: Int, tokens: Int?) {
            self.id = id
            self.state = state
            self.kind = kind
            self.task = task
            self.elapsedSeconds = elapsedSeconds
            self.tokens = tokens
        }
    }

    public var rows: [Row]
    /// 最後一行 `↓ N more`:折疊下還有幾列。
    public var hiddenCount: Int

    public init(rows: [Row], hiddenCount: Int = 0) {
        self.rows = rows
        self.hiddenCount = hiddenCount
    }

    // 正規式只建一次(#585)。Regex 不是 Sendable,但建好後不可變、只讀,所以 nonisolated(unsafe)。
    nonisolated(unsafe) private static let moreLine = /↓\s*(\d+)\s+more/
    nonisolated(unsafe) private static let rowLine = /(\S)\s+(\S+)\s{2,}(.+?)\s{2,}((?:\d+h\s*)?(?:\d+m\s*)?\d+s)\s*·\s*↓\s*([\d.,]+[kKmM]?)\s*tokens?/

    /// 最後一個 `⏺ main`(或 `● main`)標頭之後的列:`<記號> <種類>  <任務>  <1h 13m 1s> · ↓ <156.7k> tokens`。
    /// 記號 `◯○` 執行中、`⏺●◉✓✔` 完成、`✗✘×` 失敗。沒有標頭時沒有窗格(`nil`)。
    public static func parse(screen: String) -> AgentsPane? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.lastIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "⏺ main" || trimmed == "● main"
        }) else { return nil }
        var rows: [Row] = []
        var hidden = 0
        for line in lines[lines.index(after: header)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let more = trimmed.wholeMatch(of: moreLine) {
                hidden = Int(more.output.1) ?? 0
                continue
            }
            guard let match = trimmed.wholeMatch(of: rowLine),
                  let state = state(ofMarker: match.output.1) else { continue }
            rows.append(Row(
                id: rows.count, state: state, kind: String(match.output.2), task: String(match.output.3),
                elapsedSeconds: seconds(String(match.output.4)), tokens: tokens(String(match.output.5))
            ))
        }
        return AgentsPane(rows: rows, hiddenCount: hidden)
    }

    static func state(ofMarker marker: Substring) -> DelegationStatus? {
        switch marker {
        case "◯", "○": .running
        case "⏺", "●", "◉", "✓", "✔": .completed
        case "✗", "✘", "×": .failed
        default: nil
        }
    }

    /// `1h 13m 1s` → 秒。
    static func seconds(_ text: String) -> Int {
        text.matches(of: /(\d+)([hms])/).reduce(0) { total, match in
            let value = Int(match.output.1) ?? 0
            switch match.output.2 {
            case "h": return total + value * 3600
            case "m": return total + value * 60
            default: return total + value
            }
        }
    }

    /// `980`、`1,234`、`156.7k`、`1.2M` → 整數。
    static func tokens(_ text: String) -> Int? {
        let lower = text.lowercased().replacingOccurrences(of: ",", with: "")
        let multiplier: Double = lower.hasSuffix("k") ? 1_000 : lower.hasSuffix("m") ? 1_000_000 : 1
        let number = multiplier == 1 ? lower : String(lower.dropLast())
        guard let value = Double(number) else { return nil }
        return Int((value * multiplier).rounded())
    }
}
