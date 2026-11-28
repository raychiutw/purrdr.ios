import Foundation
import PurrdrCore

#if os(macOS)

/// 模擬主機上的檔案與主機腳本的輸出(流量守門，#697):不開真的 shell，依腳本的輸出格式從記憶體裡的檔案組出回應。
///
/// 腳本本身的正確性由 `LocalShellHost` 實跑的測試負責(`TranscriptCommandTests`、`HostFileScriptTests` 等);
/// 這裡只要「回應的種類與大小」和真腳本一致，流量守門才數得準。格式依 `TranscriptCommand`、`TranscriptFollowProtocol`、
/// `HostFileScript` 的說明：每行 `原始長度 TAB 剝除圖片後的行`、`appended <大小> <版本>` … `end <游標> <錨點>`、`purrdr-files 1` … `end`。
final class SimulatedHostFiles: @unchecked Sendable {
    /// 腳本看到的家目錄。
    static let home = "/Users/demo"

    private let lock = NSLock()
    private var files: [String: (data: Data, mtime: Int)] = [:]
    private let seconds: @Sendable () -> Int

    /// - Parameter seconds: 檔案的修改時間(模擬時間的秒數)。
    init(seconds: @escaping @Sendable () -> Int) { self.seconds = seconds }

    func write(_ data: Data, to relativePath: String) {
        let now = seconds()
        lock.withLock { files[relativePath] = (data, now) }
    }

    func append(_ data: Data, to relativePath: String) {
        let now = seconds()
        lock.withLock { files[relativePath] = ((files[relativePath]?.data ?? Data()) + data, now) }
    }

    func file(_ relativePath: String) -> (data: Data, mtime: Int)? { lock.withLock { files[relativePath] } }

    var paths: [String] { lock.withLock { Array(files.keys) } }

    static func relative(_ absolute: String) -> String { absolute.hasPrefix(home + "/") ? String(absolute.dropFirst(home.count + 1)) : absolute }

    // MARK: - 共用計算

    /// 版本「修改時間秒數-大小」。
    static func stamp(_ file: (data: Data, mtime: Int)) -> String { "\(file.mtime)-\(file.data.count)" }

    /// 游標前最多 64 bytes 的檢查碼(腳本用 `cksum`;這裡只要同內容同值)。游標 ≤ 0 是 `0`。
    static func anchor(_ data: Data, at offset: Int) -> String {
        guard offset > 0 else { return "0" }
        let slice = data[max(0, offset - 64)..<min(offset, data.count)]
        return String(slice.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) })
    }

    /// 檔案內容的檢查碼，格式同主機檔案腳本的版本(`<檢查碼>:<大小>`)。
    static func checksum(_ data: Data) -> String {
        "\(data.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }):\(data.count)"
    }

    /// 從 `start` 起每一行(含換行)的範圍;只收完整的行。`limit`:累計超過它且不是第一行就停。
    private static func completeLines(_ data: Data, from start: Int, to end: Int, limit: Int? = nil) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var position = start
        while position < end, let newline = data[position..<end].firstIndex(of: 0x0A) {
            let next = newline + 1
            if let limit, next - start > limit, !ranges.isEmpty { break }
            ranges.append(position..<next)
            position = next
        }
        return ranges
    }

    /// 一行輸出:`原始長度 TAB 剝除圖片後的行`(行長超過 `cap` 時截短)。
    private static func annotated(_ data: Data, _ range: Range<Int>, cap: Int? = nil) -> Data {
        let raw = data[range.lowerBound..<range.upperBound - 1]
        var text = strip(String(decoding: raw, as: UTF8.self))
        if let cap, text.utf8.count > cap { text = String(decoding: Array(text.utf8.prefix(cap)), as: UTF8.self) }
        return Data("\(raw.count)\t\(text)\n".utf8)
    }

    /// 剝除圖片(同 `TranscriptCommand.stripImages` 的兩條規則)。
    static func strip(_ text: String) -> String {
        text.replacing(/"[A-Za-z0-9+\/=]{128,}"/, with: "\"\"").replacing(/"data:[^"]*;base64,[^"]*"/, with: "\"\"")
    }

    // MARK: - 對話紀錄

    /// 開啟聊天(`TranscriptCommand.open`,參數:session id、資料夾名、行數、maxBytes)。檔案不在回 `nil`(exit 3)。
    func open(arguments: [String]) -> Data? {
        guard arguments.count == 4, let lines = Int(arguments[2]), let maxBytes = Int(arguments[3]) else { return nil }
        let relative = ".claude/projects/\(arguments[1])/\(arguments[0]).jsonl"
        guard let file = file(relative) else { return nil }
        let size = file.data.count
        var output = Data("\(Self.home)/\(relative)\n\(size)\npurrdr-window\n".utf8)
        output += window(file.data, end: size, lines: lines, chunk: maxBytes > 0 ? maxBytes : 4 << 20)
        return output
    }

    /// 視窗:終點往前 `chunk` bytes 內，最後 `lines` 行完整的行(「起點 終點」與每行)。
    private func window(_ data: Data, end: Int, lines: Int, chunk: Int) -> Data {
        let start = max(0, end - chunk)
        var ranges = Self.completeLines(data, from: start, to: end)
        // 從區塊中間開始時第一行不完整，丟掉(腳本的 `NR > 1 || s == 0`)。
        if start > 0, !ranges.isEmpty, data[start - 1] != 0x0A { ranges.removeFirst() }
        ranges = Array(ranges.suffix(lines))
        let a = ranges.first?.lowerBound ?? end
        let b = ranges.last?.upperBound ?? end
        return ranges.reduce(Data("\(a) \(b)\n".utf8)) { $0 + Self.annotated(data, $1) }
    }

    /// 長駐追蹤的一則請求「游標 版本 錨點 路徑」。
    func followReply(request: String, limit: Int = TranscriptFollowProtocol.limit, backlogLimit: Int = TranscriptFollowProtocol.backlogLimit) -> Data {
        let words = request.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard words.count == 4, let cursor = Int(words[0]) else { return Data("error 3\n".utf8) }
        guard let file = file(Self.relative(words[3])) else { return Data("error 3\n".utf8) }
        let size = file.data.count
        let stamp = Self.stamp(file)
        if size < cursor { return Data("replaced \(size)\n".utf8) }
        if words[2] != "-", Self.anchor(file.data, at: cursor) != words[2] { return Data("replaced \(size)\n".utf8) }
        if stamp == words[1] { return Data("unchanged\n".utf8) }
        let cap = size - cursor > limit ? backlogLimit : limit
        var end = cursor
        var body = Data()
        if size > cursor {
            let ranges = Self.completeLines(file.data, from: cursor, to: size, limit: cap)
            end = ranges.last?.upperBound ?? cursor
            body = ranges.reduce(Data()) { $0 + Self.annotated(file.data, $1, cap: cap) }
        }
        return Data("appended \(size) \(stamp)\n".utf8) + body + Data("end \(end) \(Self.anchor(file.data, at: end))\n".utf8)
    }

    /// 列表預覽(`TranscriptCommand.previews`,參數:標記，接著每個請求五個:key、定位方式、id、資料夾名、已知版本)。
    func previews(arguments: [String]) -> Data {
        guard let marker = arguments.first else { return Data() }
        var output = Data()
        var index = 1
        while index + 5 <= arguments.count {
            let key = arguments[index], id = arguments[index + 2], folder = arguments[index + 3], known = arguments[index + 4]
            index += 5
            output += Data("\(marker) \(key)\n".utf8)
            guard let file = file(".claude/projects/\(folder)/\(id).jsonl") else { continue }
            let size = file.data.count
            let version = "\(Self.stamp(file)) \(Self.anchor(file.data, at: size))"
            var range = "whole"
            var knownSize = -1
            if !known.isEmpty {
                let head = known.split(separator: " ").first.map(String.init) ?? ""
                knownSize = Int(head.split(separator: "-").last ?? "") ?? -1
                if known == version {
                    range = "unchanged"
                } else if knownSize >= 0, knownSize < size, size - knownSize <= TranscriptCommand.previewBytes,
                    known == "\(head) \(Self.anchor(file.data, at: knownSize))", knownSize == 0 || file.data[knownSize - 1] == 0x0A {
                    range = "appended"
                }
            }
            output += Data("\(marker)@ \(key) \(range) \(version)\n".utf8)
            switch range {
            case "appended": output += Self.stripped(file.data[knownSize...]) + Data("\n".utf8)
            case "whole": output += Self.stripped(file.data.suffix(TranscriptCommand.previewBytes)) + Data("\n".utf8)
            default: break
            }
        }
        return output
    }

    private static func stripped(_ data: some DataProtocol) -> Data {
        var text = strip(String(decoding: Data(data), as: UTF8.self))
        if !text.hasSuffix("\n") { text += "\n" }
        return Data(text.utf8)
    }

    // MARK: - 主機檔案

    /// 長駐讀取的一則請求「路徑 已知版本 [路徑 已知版本…]」。
    func hostFilesReply(request: String) -> Data {
        let fields = request.split(separator: " ").map(String.init)
        let pairs = stride(from: 0, to: fields.count - 1, by: 2).map { (HostPath(fields[$0]), fields[$0 + 1]) }
        var known: [HostPath: HostFileVersion] = [:]
        for (path, version) in pairs where version != HostFileScript.unknownVersion { known[path] = HostFileVersion(checksum: version) }
        let states: [HostFileState] = pairs.map { path, _ in
            guard let file = file(path.relative) else { return .missing }
            return .file(file.data, version: HostFileVersion(checksum: Self.checksum(file.data)))
        }
        return HostFileRequest.readIfChangedOutput(user: "demo", paths: pairs.map(\.0), files: states, known: known) + Data("end\n".utf8)
    }

    /// 找資料夾裡最新的檔案(`HostFiles.newest`)。
    func newest(directory: HostPath, prefix: String, suffix: String) -> Data {
        let match = paths
            .filter { $0.hasPrefix(directory.relative + "/" + prefix) && $0.hasSuffix(suffix) }
            .max { (file($0)?.mtime ?? 0) < (file($1)?.mtime ?? 0) }
        return HostFileRequest.newestOutput(match.map { HostPath($0) })
    }
}

#endif
