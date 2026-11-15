import Foundation

public struct TranscriptFile: Sendable, Equatable {
    public var path: String
    public var size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

public struct TranscriptChunk: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var lines: [String]

    public init(start: Int, end: Int, lines: [String]) {
        self.start = start
        self.end = end
        self.lines = lines
    }
}

public enum TranscriptTail: Sendable, Equatable {
    case unchanged
    case appended(TranscriptChunk)
    case tooFarBehind(size: Int)
    case shrank(size: Int)
}

public enum TranscriptReadError: Error, Equatable {
    case absent
    case unreadable
    case invalidReference
    /// 讀取中檔案變了或回應格式不對：重試。
    case changed
    /// 指令以其他 exit code 結束。
    case failed(exitCode: Int32?)
}

/// 讀主機上的對話紀錄(行為規格 §4.7)。以 session 為身分、永不猜檔;游標是主機上檔案的 UTF-8 byte 數。
///
/// 增量讀取用輪詢：每次以 `tail(path:from:)` 讀游標之後新增的完整行。落後太多時改讀新視窗
/// (`window`),不逐行重播大量積壓(R-B08)。
public struct TranscriptReader: Sendable {
    private let channel: any HostChannel
    private let windowChunkBytes: Int
    private let marker: @Sendable () -> String

    /// - Parameters:
    ///   - windowChunkBytes: 視窗讀取每次往前取的區塊大小(測試用小值驗證「放大區塊重數」)。
    ///   - marker: 列表預覽的分隔標記產生器(每次呼叫隨機;測試注入固定值)。
    public init(channel: any HostChannel, windowChunkBytes: Int = 4 << 20, marker: @escaping @Sendable () -> String = { "purrdr-" + UUID().uuidString }) {
        self.channel = channel
        self.windowChunkBytes = windowChunkBytes
        self.marker = marker
    }

    /// 找出 Claude Code session 的對話紀錄並取得大小。
    ///
    /// - Throws: `TranscriptReadError.absent`(還沒有檔案，例如新 session 還沒送第一個 prompt:等待即可)、
    ///   `.unreadable`(權限)、`.invalidReference`(id 不安全，不執行任何指令)。
    public func locate(sessionID: String, cwd: String) async throws -> TranscriptFile {
        guard ClaudeTranscript.isSafeSessionID(sessionID) else { throw TranscriptReadError.invalidReference }
        let output = try await run(TranscriptCommand.locate(sessionID: sessionID, projectFolder: ClaudeTranscript.projectFolder(forCWD: cwd)))
        let lines = output.lines
        guard lines.count >= 2, let size = Int(lines[1]), Self.isValidPath(lines[0]) else { throw TranscriptReadError.changed }
        return TranscriptFile(path: lines[0], size: size)
    }

    /// 讀以 `end` 為終點的最後 `lines` 行(開啟時與往上翻頁)。
    public func window(path: String, endingAt end: Int, lines: Int) async throws -> TranscriptChunk {
        guard Self.isValidPath(path), end >= 0, lines > 0 else { throw TranscriptReadError.invalidReference }
        let output = try await run(TranscriptCommand.window(path: path, end: end, lines: lines, chunkBytes: windowChunkBytes))
        guard let newline = output.stdout.firstIndex(of: 0x0A) else { throw TranscriptReadError.changed }
        let header = String(decoding: output.stdout[..<newline], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        guard header.count == 2, header[0] <= header[1], header[1] <= end else { throw TranscriptReadError.changed }
        let records = try Self.records(output.stdout[output.stdout.index(after: newline)...])
        // 回應範圍與每行原始長度加總不合 → 讀取中檔案變了，重試。
        guard records.bytes == header[1] - header[0] else { throw TranscriptReadError.changed }
        return TranscriptChunk(start: header[0], end: header[1], lines: records.lines)
    }

    /// 讀游標之後新增的完整行。
    public func tail(path: String, from cursor: Int, limit: Int = 64 << 10) async throws -> TranscriptTail {
        guard Self.isValidPath(path), cursor >= 0 else { throw TranscriptReadError.invalidReference }
        let output = try await run(TranscriptCommand.tail(path: path, from: cursor, limit: limit))
        guard let newline = output.stdout.firstIndex(of: 0x0A),
              let size = Int(String(decoding: output.stdout[..<newline], as: UTF8.self)) else { throw TranscriptReadError.changed }
        if size < cursor { return .shrank(size: size) }
        if size - cursor > limit { return .tooFarBehind(size: size) }
        let records = try Self.records(output.stdout[output.stdout.index(after: newline)...])
        guard !records.lines.isEmpty else { return .unchanged }
        return .appended(TranscriptChunk(start: cursor, end: cursor + records.bytes, lines: records.lines))
    }

    // MARK: - 輸出

    private struct Output {
        var stdout: Data
        var lines: [String] { String(decoding: stdout, as: UTF8.self).split(separator: "\n").map(String.init) }
    }

    /// 執行並收集輸出;依 exit code 判斷，不比對 stderr 文字(R-S15)。
    private func run(_ command: String) async throws -> Output {
        let session = try await channel.execute(command)
        var stdout = Data()
        var exitCode: Int32?
        do {
            for try await event in session.output {
                switch event {
                case .stdout(let data): stdout.append(data)
                case .stderr: break
                case .exit(let code, _): exitCode = code
                }
            }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        switch exitCode {
        case 0?: return Output(stdout: stdout)
        case 3?: throw TranscriptReadError.absent
        case 4?, 5?: throw TranscriptReadError.unreadable
        default: throw TranscriptReadError.failed(exitCode: exitCode)
        }
    }

    /// 「原始 byte 長度 TAB 行」的紀錄。回傳行與原始 byte 總數(含換行)。
    static func records(_ data: Data.SubSequence) throws -> (lines: [String], bytes: Int) {
        var lines: [String] = []
        var bytes = 0
        for record in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09),
                  let length = Int(String(decoding: record[..<tab], as: UTF8.self)) else { throw TranscriptReadError.changed }
            lines.append(String(decoding: record[record.index(after: tab)...], as: UTF8.self))
            bytes += length + 1
        }
        return (lines, bytes)
    }

    /// 主機回報的路徑：必須是絕對路徑、以 `.jsonl` 結尾、沒有 `..` 段、沒有 NUL／CR／LF(行為規格 §4.0)。
    static func isValidPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".jsonl")
            && !path.split(separator: "/").contains("..")
            && !path.contains { $0 == "\0" || $0 == "\r" || $0 == "\n" }
    }
}

/// 一個要讀預覽的聊天。
public struct PreviewRequest: Sendable, Equatable {
    public var key: String
    public var sessionID: String
    public var cwd: String

    public init(key: String, sessionID: String, cwd: String) {
        self.key = key
        self.sessionID = sessionID
        self.cwd = cwd
    }
}

extension TranscriptReader {
    /// 列表預覽：一次往返讀所有聊天對話紀錄的檔尾(行為規格 §4.7、R-L01)。session id 不安全的請求略過。
    /// 回傳 key → 最後一則可讀訊息;沒有檔案或沒有可讀訊息的聊天不在結果裡。
    public func previews(of requests: [PreviewRequest]) async throws -> [String: MessagePreview] {
        let safe = requests.filter { ClaudeTranscript.isSafeSessionID($0.sessionID) }
        guard !safe.isEmpty else { return [:] }
        let marker = marker()
        let command = TranscriptCommand.previews(
            marker: marker,
            requests: safe.map { ($0.key, $0.sessionID, ClaudeTranscript.projectFolder(forCWD: $0.cwd)) }
        )
        let output = try await run(command)
        var linesByKey: [String: [String]] = [:]
        var current: String?
        let prefix = marker + " "
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix(prefix) {
                current = String(line.dropFirst(prefix.count))
                if let current { linesByKey[current, default: []] = [] }
            } else if let current {
                linesByKey[current, default: []].append(String(line))
            }
        }
        // 檔尾的第一行多半被切在中間，解析時自然略過。
        return linesByKey.compactMapValues { lines in
            Conversation.preview(of: lines.flatMap(ClaudeTranscriptParser.messages(in:)))
        }
    }
}
