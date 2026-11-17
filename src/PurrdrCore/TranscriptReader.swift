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
    /// 符合 session 的檔案不只一個:不開任何檔、不依新舊猜(行為規格 §4.3、§4.5)。
    case ambiguous
    /// 只找到壓縮過的檔案(Codex 會壓縮 7 天未動的 rollout,§4.2):目前讀不了，但不是不存在。
    case compressed
    /// 檔案的 header 與回報的 session 不符(Pi／OMP,§4.5)。下次重新定位。
    case mismatch
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
    private let connection: any HostConnection
    private let windowChunkBytes: Int
    private let marker: @Sendable () -> String

    /// - Parameters:
    ///   - windowChunkBytes: 視窗讀取每次往前取的區塊大小(測試用小值驗證「放大區塊重數」)。
    ///   - marker: 列表預覽的分隔標記產生器(每次呼叫隨機;測試注入固定值)。
    public init(
        connection: any HostConnection, windowChunkBytes: Int = 4 << 20,
        marker: @escaping @Sendable () -> String = { "purrdr-" + UUID().uuidString }
    ) {
        self.connection = connection
        self.windowChunkBytes = windowChunkBytes
        self.marker = marker
    }

    /// 找出 Claude Code session 的對話紀錄並取得大小。
    ///
    /// - Throws: `TranscriptReadError.absent`(還沒有檔案，例如新 session 還沒送第一個 prompt:等待即可)、
    ///   `.unreadable`(權限)、`.invalidReference`(id 不安全，不執行任何指令)。
    public func locate(sessionID: String, cwd: String) async throws -> TranscriptFile {
        guard ClaudeTranscript.isSafeSessionID(sessionID) else { throw TranscriptReadError.invalidReference }
        let output = try await run(.locateClaude(sessionID: sessionID, projectFolder: ClaudeTranscript.projectFolder(forCWD: cwd)))
        let lines = output.lines
        guard lines.count >= 2, let size = Int(lines[1]), Self.isValidPath(lines[0]) else { throw TranscriptReadError.changed }
        return TranscriptFile(path: lines[0], size: size)
    }

    /// 找出任一種 agent 的對話紀錄並取得大小。
    ///
    /// - Throws: `.absent`(還沒有檔案)、`.unreadable`(權限)、`.ambiguous`(不只一個候選)、`.mismatch`(header 不符)、
    ///   `.invalidReference`(id 或路徑不安全，不執行任何指令)。
    public func locate(_ target: TranscriptTarget) async throws -> TranscriptFile {
        let expectedSuffix: String?
        switch target.location {
        case .claude(let sessionID, let cwd):
            return try await locate(sessionID: sessionID, cwd: cwd)
        case .grok(let id):
            guard ClaudeTranscript.isSafeSessionID(id) else { throw TranscriptReadError.invalidReference }
            expectedSuffix = "\(id)/updates.jsonl"
        case .antigravity(let id), .piJournal(let id), .codex(let id):
            guard ClaudeTranscript.isSafeSessionID(id) else { throw TranscriptReadError.invalidReference }
            expectedSuffix = nil
        case .reportedPath(let path):
            guard Self.isValidPath(path) else { throw TranscriptReadError.invalidReference }
            expectedSuffix = nil
        }
        let readsHeader = target.format == .piJournal || target.format == .codex
        let lines = try await run(.locate(target.location, readsHeader: readsHeader)).lines
        guard lines.count >= 2, let size = Int(lines[1]), Self.isValidPath(lines[0]),
              expectedSuffix.map({ Self.hasComponents(lines[0], $0) }) ?? true else { throw TranscriptReadError.changed }
        if case .codex(let id) = target.location {
            // 路徑必須是 `-<id>(_<rolloutId>)?.jsonl`;第一行是這個 session 的 session_meta(§4.2)。
            guard Self.isCodexRollout(lines[0], id: id) else { throw TranscriptReadError.changed }
            guard lines.count >= 3, CodexTranscriptParser.headerMatches(lines[2], expectedID: id) else { throw TranscriptReadError.mismatch }
        } else if readsHeader {
            let expectedID: String? = if case .piJournal(let id) = target.location { id } else { nil }
            guard PiJournalParser.headerMatches(Array(lines.dropFirst(2)), expectedID: expectedID) else { throw TranscriptReadError.mismatch }
        }
        return TranscriptFile(path: lines[0], size: size)
    }

    /// 讀以 `end` 為終點的最後 `lines` 行(開啟時與往上翻頁)。
    public func window(path: String, endingAt end: Int, lines: Int) async throws -> TranscriptChunk {
        guard Self.isValidPath(path), end >= 0, lines > 0 else { throw TranscriptReadError.invalidReference }
        let output = try await run(.window(path: path, end: end, lines: lines, chunkBytes: windowChunkBytes))
        guard let newline = output.stdout.firstIndex(of: 0x0A) else { throw TranscriptReadError.changed }
        let header = String(decoding: output.stdout[..<newline], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        guard header.count == 2, header[0] <= header[1], header[1] <= end else { throw TranscriptReadError.changed }
        let records = try Self.records(output.stdout[output.stdout.index(after: newline)...])
        // 回應範圍與每行原始長度加總不合 → 讀取中檔案變了，重試。
        guard records.bytes == header[1] - header[0] else { throw TranscriptReadError.changed }
        return TranscriptChunk(start: header[0], end: header[1], lines: records.lines)
    }

    /// 檔案目前的大小(開啟視窗的上限)。用追蹤指令、游標放在檔尾之後:主機只印大小。
    public func size(path: String) async throws -> Int {
        switch try await tail(path: path, from: Self.probeCursor) {
        case .shrank(let size), .tooFarBehind(let size): size
        case .unchanged, .appended: throw TranscriptReadError.changed
        }
    }

    public static let probeCursor = 1 << 50

    /// 讀游標之後新增的完整行。
    public func tail(path: String, from cursor: Int, limit: Int = 64 << 10) async throws -> TranscriptTail {
        guard Self.isValidPath(path), cursor >= 0 else { throw TranscriptReadError.invalidReference }
        let output = try await run(.tail(path: path, from: cursor, limit: limit))
        guard let newline = output.stdout.firstIndex(of: 0x0A),
              let size = Int(String(decoding: output.stdout[..<newline], as: UTF8.self)) else { throw TranscriptReadError.changed }
        if size < cursor { return .shrank(size: size) }
        if size - cursor > limit { return .tooFarBehind(size: size) }
        let records = try Self.records(output.stdout[output.stdout.index(after: newline)...])
        guard !records.lines.isEmpty else { return .unchanged }
        return .appended(TranscriptChunk(start: cursor, end: cursor + records.bytes, lines: records.lines))
    }

    // MARK: - 輸出

    struct Output {
        var stdout: Data
        var lines: [String] { String(decoding: stdout, as: UTF8.self).split(separator: "\n").map(String.init) }
    }

    /// 經主機連線讀一次;主機回報的失敗丟 `TranscriptReadError`。
    func run(_ request: TranscriptRequest) async throws -> Output {
        Output(stdout: try await connection.readTranscript(request))
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

    /// 路徑的最後幾段剛好是 `suffix`(以 `/` 分段;Windows 路徑的 `\` 也算分隔)。
    static func hasComponents(_ path: String, _ suffix: String) -> Bool {
        let expected = suffix.split(separator: "/")
        return Array(HostPathSyntax.components(path).suffix(expected.count)) == expected
    }

    /// Codex rollout 的檔名：`…-<id>.jsonl` 或倒帶後的 `…-<id>_<rolloutId>.jsonl`。
    static func isCodexRollout(_ path: String, id: String) -> Bool {
        guard let name = HostPathSyntax.lastComponent(path), name.hasPrefix("rollout-") else { return false }
        let suffix = "-\(id).jsonl"
        if name.hasSuffix(suffix) { return true }
        guard let range = name.range(of: "-\(id)_", options: .backwards), name.hasSuffix(".jsonl") else { return false }
        let rollout = name[range.upperBound..<name.index(name.endIndex, offsetBy: -".jsonl".count)]
        return !rollout.isEmpty && rollout.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// 主機回報的路徑：必須是絕對路徑(POSIX `/…` 或 Windows `C:\…`)、以 `.jsonl` 結尾、沒有 `..` 段、
    /// 沒有 NUL／CR／LF(行為規格 §4.0)。
    static func isValidPath(_ path: String) -> Bool {
        HostPathSyntax.isSafeAbsolute(path) && path.hasSuffix(".jsonl")
    }
}

/// 一個要讀預覽的聊天。
public struct PreviewRequest: Sendable, Equatable {
    public var key: String
    public var target: TranscriptTarget

    public init(key: String, target: TranscriptTarget) {
        self.key = key
        self.target = target
    }

    /// Claude Code session 的預覽。
    public init(key: String, sessionID: String, cwd: String) {
        self.init(key: key, target: TranscriptTarget(format: .claude, location: .claude(sessionID: sessionID, cwd: cwd), sessionKey: sessionID))
    }
}

extension TranscriptReader {
    /// 列表預覽：一次往返讀所有聊天對話紀錄的檔尾(行為規格 §4.7、R-L01)。session id 或路徑不安全的請求略過。
    /// 回傳 key → 最後一則可讀訊息;沒有檔案、有歧義、header 不符(Pi／OMP)或沒有可讀訊息的聊天不在結果裡。
    public func previews(of requests: [PreviewRequest]) async throws -> [String: MessagePreview] {
        guard requests.contains(where: { TranscriptCommand.PreviewEntry($0) != nil }) else { return [:] }
        let marker = marker()
        let output = try await run(.previews(marker: marker, requests: requests))
        var bodies: [String: [String]] = [:]
        var headers: [String: [String]] = [:]
        var current: (key: String, isHeader: Bool)?
        let bodyPrefix = marker + " "
        let headerPrefix = marker + "! "
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix(headerPrefix) {
                let key = String(line.dropFirst(headerPrefix.count))
                current = (key, true)
                headers[key] = []
            } else if line.hasPrefix(bodyPrefix) {
                let key = String(line.dropFirst(bodyPrefix.count))
                current = (key, false)
                bodies[key] = []
            } else if let current {
                if current.isHeader { headers[current.key, default: []].append(String(line)) } else { bodies[current.key, default: []].append(String(line)) }
            }
        }
        var previews: [String: MessagePreview] = [:]
        for request in requests {
            guard let lines = bodies[request.key] else { continue }
            if request.target.format == .piJournal {
                let expectedID: String? = if case .piJournal(let id) = request.target.location { id } else { nil }
                guard PiJournalParser.headerMatches(headers[request.key] ?? [], expectedID: expectedID) else { continue }
            }
            if case .codex(let id) = request.target.location {
                guard let header = headers[request.key]?.first, CodexTranscriptParser.headerMatches(header, expectedID: id) else { continue }
            }
            // 檔尾的第一行多半被切在中間，解析時自然略過。
            previews[request.key] = Conversation.preview(of: lines.flatMap(request.target.format.messages(in:)))
        }
        return previews
    }
}

extension TranscriptReader {
    /// 找出呼叫 `callID` 啟動的 subagent 對話紀錄路徑(行為規格 §4.6、R-W02)。
    ///
    /// 讀 `<session>/subagents/` 下內容含這個 id 的 meta,解析後 `toolUseId` 必須**完全相等**;**絕不用最新檔**
    /// (兩個 agent 可在同一毫秒啟動)。完全相等的不只一個時無法判斷，當作改變了(`.changed`)而不是挑一個。
    ///
    /// - Throws: `.absent`(還沒有 meta:啟動中，稍後再找)、`.invalidReference`(id 或資料夾不安全，不執行指令)。
    public func locateSubagent(sessionFolder: String, callID: String) async throws -> String {
        guard ClaudeTranscript.isSafeDelegationID(callID), ClaudeTranscript.isValidFolder(sessionFolder) else {
            throw TranscriptReadError.invalidReference
        }
        let output = try await run(.findSubagent(sessionFolder: sessionFolder, callID: callID))
        let lines = output.lines
        var matches: [String] = []
        for pair in stride(from: 0, to: lines.count - 1, by: 2) {
            let metaPath = lines[pair]
            guard metaPath.hasSuffix(".meta.json"),
                  let meta = ClaudeTranscriptParser.jsonObject(lines[pair + 1]),
                  meta["toolUseId"] as? String == callID else { continue }
            let transcript = String(metaPath.dropLast(".meta.json".count)) + ".jsonl"
            if Self.isValidPath(transcript) { matches.append(transcript) }
        }
        guard !matches.isEmpty else { throw TranscriptReadError.absent }
        guard matches.count == 1 else { throw TranscriptReadError.changed }
        return matches[0]
    }
}

extension TranscriptReader {
    /// 父對話紀錄中指名這個委派(呼叫 id 或 agent id)的行(R-W04)。內容的 checksum 與 `knownChecksum` 相同時
    /// `lines` 是 `nil`(主機只回一行)。
    public func delegationLines(path: String, callID: String, agentID: String?, knownChecksum: String?) async throws -> (checksum: String, lines: [String]?) {
        guard Self.isValidPath(path), ClaudeTranscript.isSafeDelegationID(callID),
              agentID.map(ClaudeTranscript.isSafeDelegationID) ?? true else { throw TranscriptReadError.invalidReference }
        let output = try await run(.delegationLines(path: path, callID: callID, agentID: agentID ?? callID, knownChecksum: knownChecksum ?? ""))
        guard let newline = output.stdout.firstIndex(of: 0x0A) else { throw TranscriptReadError.changed }
        let checksum = String(decoding: output.stdout[..<newline], as: UTF8.self)
        if checksum == knownChecksum { return (checksum, nil) }
        return (checksum, try Self.records(output.stdout[output.stdout.index(after: newline)...]).lines)
    }
}
