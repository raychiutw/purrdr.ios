import Foundation

public struct TranscriptFile: Sendable, Equatable {
    public var path: String
    public var size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

/// 開啟聊天一次讀到的:對話紀錄的位置與大小,加上以那個大小為終點的最後幾行(#656)。
public struct TranscriptOpening: Sendable, Equatable {
    public var file: TranscriptFile
    public var chunk: TranscriptChunk

    public init(file: TranscriptFile, chunk: TranscriptChunk) {
        self.file = file
        self.chunk = chunk
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
    /// 檔案被換成同長或更長的新檔(HTTPS 的主機服務比對得出來);`tail` 讀成 `.shrank(size:)`。
    case replaced(size: Int)
    /// 指令以其他 exit code 結束。
    case failed(exitCode: Int32?)
}

extension TranscriptReadError {
    /// 對話紀錄指令的 exit code(POSIX 與 Windows 腳本相同，行為規格 §4.7)。
    public enum ExitCode {
        public static let absent: Int32 = 3
        public static let folderNotSearchable: Int32 = 4
        public static let fileUnreadable: Int32 = 5
        public static let ambiguous: Int32 = 6
        public static let compressed: Int32 = 7
    }

    /// 主機指令的結束狀態對應的錯誤;成功(0)是 `nil`。沒有結束狀態也是失敗。
    public init?(exitStatus: Int32?) {
        switch exitStatus {
        case .some(0): return nil
        case .some(ExitCode.absent): self = .absent
        case .some(ExitCode.folderNotSearchable), .some(ExitCode.fileUnreadable): self = .unreadable
        case .some(ExitCode.ambiguous): self = .ambiguous
        case .some(ExitCode.compressed): self = .compressed
        default: self = .failed(exitCode: exitStatus)
        }
    }
}

/// 讀主機上的對話紀錄(行為規格 §4.7)。以 session 為身分、永不猜檔;游標是主機上檔案的 UTF-8 byte 數。
///
/// 增量讀取用輪詢：每次以 `tail(path:from:)` 讀游標之後新增的完整行。落後太多時改讀新視窗
/// (`window`),不逐行重播大量積壓(R-B08)。
public struct TranscriptReader: Sendable {
    let connection: any HostConnection

    public init(connection: any HostConnection) {
        self.connection = connection
    }

    /// 找出 Claude Code session 的對話紀錄並取得大小(含 worktree 後備)。
    ///
    /// - Throws: `TranscriptReadError.absent`(還沒有檔案，例如新 session 還沒送第一個 prompt:等待即可)、
    ///   `.unreadable`(權限)、`.invalidReference`(id 不安全，不執行任何指令)。
    public func locate(sessionID: String, cwd: String) async throws -> TranscriptFile {
        try await locate(TranscriptLocation(locator: .claude, reference: .id(sessionID), cwd: cwd))
    }

    /// 找出任一種 agent 的對話紀錄並取得大小。
    ///
    /// - Throws: `.absent`(還沒有檔案)、`.unreadable`(權限)、`.ambiguous`(不只一個候選)、`.mismatch`(header 不符)、
    ///   `.invalidReference`(id 或路徑不安全，不執行任何指令)。
    public func locate(_ target: TranscriptTarget) async throws -> TranscriptFile {
        try await locate(target.location)
    }

    package func locate(_ location: TranscriptLocation) async throws -> TranscriptFile {
        try await connection.locateTranscript(location)
    }

    /// 定位結果(路徑、大小，再接 header 行)的檢查與解析;SSH 腳本輸出與 HTTPS 的 `transcript.locate` 共用。
    package static func locatedFile(lines: [String], for location: TranscriptLocation) throws -> TranscriptFile {
        let locator = location.locator
        guard lines.count >= 2, let size = Int(lines[1]), Self.isValidPath(lines[0]) else { throw TranscriptReadError.changed }
        if case .id(let id) = location.reference, let pathCheck = locator.pathCheck, !pathCheck(lines[0], id) {
            throw TranscriptReadError.changed
        }
        if let headerCheck = locator.headerCheck {
            let expectedID: String? = if case .id(let id) = location.reference { id } else { nil }
            guard headerCheck(Array(lines.dropFirst(2)), expectedID) else { throw TranscriptReadError.mismatch }
        }
        return TranscriptFile(path: lines[0], size: size)
    }

    /// 讀以 `end` 為終點的最後 `lines` 行(開啟時與往上翻頁)。
    ///
    /// `maxBytes` 有值時範圍最多往前取那麼多 bytes(只含完整的行，可能少於 `lines` 行，也可能一行都放不下而是空的;
    /// 呼叫端自己決定要不要放寬)。HTTPS 主機服務 0.11.0 起的 `transcript.window` 有 `max_bytes`(`HostServiceFeature.transcriptWindowMaxBytes`),更舊的只照行數。
    public func window(path: String, endingAt end: Int, lines: Int, maxBytes: Int? = nil) async throws -> TranscriptChunk {
        guard Self.isValidPath(path), end >= 0, lines > 0, (maxBytes ?? 1) > 0 else { throw TranscriptReadError.invalidReference }
        return try await connection.readTranscriptWindow(path: path, end: end, lines: lines, maxBytes: maxBytes ?? 0)
    }

    /// 開啟聊天:定位並讀以檔案大小為終點的最後 `lines` 行(`maxBytes` 的意義同 `window`)。SSH 一次往返;失敗丟 `TranscriptReadError`。
    public func open(_ target: TranscriptTarget, lines: Int, maxBytes: Int? = nil) async throws -> TranscriptOpening {
        guard lines > 0, (maxBytes ?? 1) > 0 else { throw TranscriptReadError.invalidReference }
        let opening = try await connection.openTranscript(target.location, lines: lines, maxBytes: maxBytes ?? 0)
        guard Self.isValidPath(opening.file.path) else { throw TranscriptReadError.invalidReference }
        return opening
    }

    public static let defaultWindowChunkBytes = 4 << 20

    /// 檔案目前的大小(開啟視窗的上限)。用追蹤指令、游標放在檔尾之後:主機只印大小。
    public func size(path: String) async throws -> Int {
        switch try await tail(path: path, from: Self.probeCursor) {
        case .shrank(let size), .tooFarBehind(let size): size
        case .unchanged, .appended: throw TranscriptReadError.changed
        }
    }

    public static let probeCursor = 1 << 50

    /// 聊天第一次從主機讀的短視窗(#356):最後 40 行且不超過 64 KiB，取較小者;更早的訊息往上捲才一段一段載入。數值只在這裡。
    public static let openingLines = 40
    public static let openingMaxBytes = 64 << 10

    /// 不再追蹤 `path`(對話關閉或換了 session;見 `HostConnection.stopFollowingTranscript`)。
    public func stopFollowing(path: String) async {
        await connection.stopFollowingTranscript(path: path)
    }

    /// 追蹤 `path` 的尾端(見 `HostConnection.followTranscript`)。路徑不安全時串流立刻以 `.invalidReference` 結束。
    public func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        guard Self.isValidPath(path), cursor >= 0 else {
            return AsyncThrowingStream { $0.finish(throwing: TranscriptReadError.invalidReference) }
        }
        return await connection.followTranscript(path: path, from: cursor, pace: pace)
    }

    /// 讀游標之後新增的完整行。
    public func tail(path: String, from cursor: Int, limit: Int = 64 << 10) async throws -> TranscriptTail {
        try await tailReportingSize(path: path, from: cursor, limit: limit).tail
    }

    /// 同 `tail`,另外回報主機上的檔案大小。
    func tailReportingSize(path: String, from cursor: Int, limit: Int = 64 << 10) async throws -> (tail: TranscriptTail, size: Int) {
        guard Self.isValidPath(path), cursor >= 0 else { throw TranscriptReadError.invalidReference }
        let read = try await connection.readTranscriptTail(path: path, from: cursor, limit: limit, catchUp: false)
        return (read.tail, read.size)
    }

    /// 追蹤讀取的結果判讀:主機回報的檔案大小與游標之後的完整行(`records` 在需要時才解析);SSH 腳本輸出與 HTTPS 的推送共用。
    package static func interpretTail(
        size: Int, cursor: Int, limit: Int, catchUp: Bool, records parse: () throws -> (lines: [String], bytes: Int)
    ) throws -> TranscriptTailRead {
        if size < cursor { return TranscriptTailRead(tail: .shrank(size: size), size: size) }
        if !catchUp, size - cursor > limit { return TranscriptTailRead(tail: .tooFarBehind(size: size), size: size) }
        let records = try parse()
        if catchUp {
            // 一行都沒拿到卻落後超過上限：主機不能分段接著讀(#173 之前的主機服務落後太多就結束追蹤),
            // 回報落後太多讓呼叫端讀新視窗，不卡在同一個游標。SSH 的主機腳本與 #173 起的主機服務會把超大單行截短後送出，
            // 只有那一行還沒寫完時會走到這裡。
            if records.lines.isEmpty, size - cursor > limit { return TranscriptTailRead(tail: .tooFarBehind(size: size), size: size) }
            guard !records.lines.isEmpty else { return TranscriptTailRead(tail: .unchanged, size: size) }
            guard cursor + records.bytes <= size else { throw TranscriptReadError.changed }
        }
        guard !records.lines.isEmpty else { return TranscriptTailRead(tail: .unchanged, size: size) }
        return TranscriptTailRead(
            tail: .appended(TranscriptChunk(start: cursor, end: cursor + records.bytes, lines: records.lines)), size: size)
    }

    /// 即時追蹤的單次上限(#130)。
    ///
    /// 256 KiB:是開啟時「落後太多」門檻(64 KiB)的 4 倍，本機量到的 2 秒寫入量多半一次讀完。主機端把超大單行截短到
    /// 上限，所以傳輸量不超過上限，期限是 20 秒加上 256 KiB 以 32 KiB/s 估算的 8 秒(約 28 秒)。
    public static let catchUpLimit = 256 << 10

    /// 上次讀完後主機上還有超過 `catchUpLimit` 沒讀(Agent 高速輸出)時，下一次的上限(#130 review 3)。
    ///
    /// 1 MiB:每次輪詢仍只有一個對話紀錄指令(R-F01 的指令預算不變),工作中每 2 秒一次就是每分鐘最多約 30 MiB,
    /// 遠快於 Agent 寫對話紀錄的速度，一兩次輪詢就追上;期限 20 秒加上 32 秒(約 53 秒),只有真的落後時才用這麼長的期限。
    /// Heeler 每次輪詢最多 2 MiB(經 SFTP 分成多個各有期限的讀取);我們一個 shell 指令只有一個期限，取一半。
    public static let catchUpBacklogLimit = 1 << 20

    /// 分段追趕：從游標讀最多 `limit` bytes 的完整行，即使後面還有(畫面已有內容時的即時追蹤，#130)。
    /// 不回報 `tooFarBehind`:落後多少都從游標接著讀，下一次從新游標繼續。第一行就超過 `limit` 時，主機把它
    /// (剝除圖片後)截短到 `limit` bytes 送出，游標照原始長度前進：絕不卡在同一個游標;截短的行解析不出來，畫面略過。
    public func catchUp(path: String, from cursor: Int, limit: Int = catchUpLimit) async throws -> TranscriptTail {
        try await catchUpReportingSize(path: path, from: cursor, limit: limit).tail
    }

    /// 同 `catchUp`,另外回報主機上的檔案大小。
    func catchUpReportingSize(path: String, from cursor: Int, limit: Int) async throws -> (tail: TranscriptTail, size: Int) {
        guard Self.isValidPath(path), cursor >= 0, limit > 0 else { throw TranscriptReadError.invalidReference }
        let read = try await connection.readTranscriptTail(path: path, from: cursor, limit: limit, catchUp: true)
        return (read.tail, read.size)
    }

    /// 即時追蹤讀一次(#130、F5.3 第 3 點、R-B08)。
    ///
    /// 還沒追上(`isLive == false`:剛從快取恢復、或畫面重新可見)時，落後超過 64 KiB 回報 `tooFarBehind`,由呼叫端讀新視窗，
    /// 不逐段重播積壓;追上之後落後多少都分段接著讀(`catchUp`),上次讀完還落後很多時這次讀大一點(`catchUpBacklogLimit`)。
    /// 回傳這次的結果與下一次要用的狀態;`tooFarBehind`／`shrank` 時狀態不變(呼叫端改讀視窗)。
    public func follow(path: String, _ state: TranscriptFollow) async throws -> (tail: TranscriptTail, next: TranscriptFollow) {
        let read = state.isLive
            ? try await catchUpReportingSize(path: path, from: state.cursor, limit: state.limit)
            : try await tailReportingSize(path: path, from: state.cursor)
        var next = state
        switch read.tail {
        case .appended(let chunk):
            next = TranscriptFollow(cursor: chunk.end, isLive: true, backlog: read.size - chunk.end)
        case .unchanged:
            // 只有未完成的行(還在寫)不算追上：之後一次寫很多時，重新開啟的畫面仍讀新視窗。
            next = TranscriptFollow(cursor: state.cursor, isLive: state.isLive || read.size == state.cursor, backlog: read.size - state.cursor)
        case .tooFarBehind, .shrank:
            break
        }
        return (read.tail, next)
    }

    // MARK: - 輸出

    /// 「原始 byte 長度 TAB 行」的紀錄。回傳行與原始 byte 總數(含換行)。
    package static func records(_ data: Data.SubSequence) throws -> (lines: [String], bytes: Int) {
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
    package static func isValidPath(_ path: String) -> Bool {
        HostPathSyntax.isSafeAbsolute(path) && path.hasSuffix(".jsonl")
    }
}

/// 對話紀錄的腳本輸出實作(SSH 連線方式用,ADR-0015):送 `TranscriptRequest`、解析主機腳本的輸出。HTTPS 直接對應主機服務訊息,不經這裡。
package struct TranscriptWireReader: Sendable {
    private let wire: any HerdrWire
    private let windowChunkBytes: Int
    private let marker: @Sendable () -> String

    /// - Parameters:
    ///   - windowChunkBytes: 視窗讀取每次往前取的區塊大小(測試用小值驗證「放大區塊重數」)。
    ///   - marker: 列表預覽的分隔標記產生器(每次呼叫隨機;測試注入固定值)。
    package init(
        wire: any HerdrWire, windowChunkBytes: Int = TranscriptReader.defaultWindowChunkBytes,
        marker: @escaping @Sendable () -> String = { "purrdr-" + UUID().uuidString }
    ) {
        self.wire = wire
        self.windowChunkBytes = windowChunkBytes
        self.marker = marker
    }

    /// `locate` 的腳本輸出實作。
    package func locate(_ location: TranscriptLocation) async throws -> TranscriptFile {
        guard location.isSafe else { throw TranscriptReadError.invalidReference }
        return try TranscriptReader.locatedFile(lines: try await run(.locate(location)).lines, for: location)
    }

    /// `window` 的腳本輸出實作。
    package func window(path: String, endingAt end: Int, lines: Int, maxBytes: Int?) async throws -> TranscriptChunk {
        guard TranscriptReader.isValidPath(path), end >= 0, lines > 0, (maxBytes ?? 1) > 0 else { throw TranscriptReadError.invalidReference }
        let output = try await run(.window(path: path, end: end, lines: lines, chunkBytes: windowChunkBytes, maxBytes: maxBytes ?? 0))
        guard let newline = output.stdout.firstIndex(of: 0x0A) else { throw TranscriptReadError.changed }
        let header = String(decoding: output.stdout[..<newline], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        guard header.count == 2, header[0] <= header[1], header[1] <= end else { throw TranscriptReadError.changed }
        let records = try TranscriptReader.records(output.stdout[output.stdout.index(after: newline)...])
        // 回應範圍與每行原始長度加總不合 → 讀取中檔案變了，重試。
        guard records.bytes == header[1] - header[0] else { throw TranscriptReadError.changed }
        return TranscriptChunk(start: header[0], end: header[1], lines: records.lines)
    }

    /// `tail`／`catchUp` 的腳本輸出實作。
    package func tail(path: String, from cursor: Int, limit: Int, catchUp: Bool) async throws -> TranscriptTailRead {
        guard TranscriptReader.isValidPath(path), cursor >= 0, limit > 0 else { throw TranscriptReadError.invalidReference }
        let output: Output
        do {
            output = try await run(catchUp ? .catchUp(path: path, from: cursor, limit: limit) : .tail(path: path, from: cursor, limit: limit))
        } catch TranscriptReadError.replaced(let size) {
            // 主機服務(HTTPS)回報檔案被換掉：與 SSH 的「變小」同樣是真正的斷層。
            return TranscriptTailRead(tail: .shrank(size: size), size: size)
        }
        guard let newline = output.stdout.firstIndex(of: 0x0A),
              let size = Int(String(decoding: output.stdout[..<newline], as: UTF8.self)) else { throw TranscriptReadError.changed }
        return try TranscriptReader.interpretTail(size: size, cursor: cursor, limit: limit, catchUp: catchUp) {
            try TranscriptReader.records(output.stdout[output.stdout.index(after: newline)...])
        }
    }

    struct Output {
        var stdout: Data
        var lines: [String] { String(decoding: stdout, as: UTF8.self).split(separator: "\n").map(String.init) }
    }

    /// 經主機連線讀一次;主機回報的失敗丟 `TranscriptReadError`。
    func run(_ request: TranscriptRequest) async throws -> Output {
        Output(stdout: try await wire.readTranscript(request))
    }

    /// `previewReadings` 的腳本輸出實作:分段解析腳本輸出成每個聊天的原始內容。
    package func previews(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] {
        let marker = marker()
        let output = try await run(.previews(marker: marker, requests: requests))
        var bodies: [String: [String]] = [:]
        var headers: [String: [String]] = [:]
        var ranges: [String: PreviewRangeLine] = [:]
        var current: (key: String, isHeader: Bool)?
        let bodyPrefix = marker + " "
        let headerPrefix = marker + "! "
        let rangePrefix = marker + "@ "
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix(rangePrefix) {
                guard let range = PreviewRangeLine(line.dropFirst(rangePrefix.count)) else {
                    current = nil
                    continue
                }
                ranges[range.key] = range
                current = (range.key, false)
                bodies[range.key] = []
            } else if line.hasPrefix(headerPrefix) {
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
        var result: [String: TranscriptPreviewBody] = [:]
        for (key, lines) in bodies {
            result[key] = TranscriptPreviewBody(lines: lines, header: headers[key], change: ranges[key]?.change, version: ranges[key]?.version)
        }
        return result
    }

    /// `locateSubagent` 的腳本輸出實作。
    package func locateSubagent(sessionFolder: String, callID: String) async throws -> String {
        let output = try await run(.findSubagent(sessionFolder: sessionFolder, callID: callID))
        let lines = output.lines
        var matches: [String] = []
        for pair in stride(from: 0, to: lines.count - 1, by: 2) {
            let metaPath = lines[pair]
            guard metaPath.hasSuffix(".meta.json"),
                  let meta = ClaudeTranscriptParser.jsonObject(lines[pair + 1]),
                  meta["toolUseId"] as? String == callID else { continue }
            let transcript = String(metaPath.dropLast(".meta.json".count)) + ".jsonl"
            if TranscriptReader.isValidPath(transcript) { matches.append(transcript) }
        }
        guard !matches.isEmpty else { throw TranscriptReadError.absent }
        guard matches.count == 1 else { throw TranscriptReadError.changed }
        return matches[0]
    }

    /// `delegationLines` 的腳本輸出實作。
    package func delegationLines(path: String, callID: String, agentID: String, knownChecksum: String?) async throws -> DelegationRead {
        let output = try await run(.delegationLines(path: path, callID: callID, agentID: agentID, knownChecksum: knownChecksum ?? ""))
        guard let newline = output.stdout.firstIndex(of: 0x0A) else { throw TranscriptReadError.changed }
        let checksum = String(decoding: output.stdout[..<newline], as: UTF8.self)
        if checksum == knownChecksum { return DelegationRead(checksum: checksum, lines: nil) }
        return DelegationRead(checksum: checksum, lines: try TranscriptReader.records(output.stdout[output.stdout.index(after: newline)...]).lines)
    }
}


/// 一個要讀預覽的聊天。
public struct PreviewRequest: Sendable, Equatable {
    public var key: String
    public var target: TranscriptTarget
    /// 上次讀到的對話紀錄版本(`PreviewReading.version`):沒變主機只回 unchanged,有附加只回附加的部分(#205)。
    public var knownVersion: PreviewVersion?

    public init(key: String, target: TranscriptTarget) {
        self.key = key
        self.target = target
    }

    /// Claude Code session 的預覽。
    public init(key: String, sessionID: String, cwd: String) {
        self.init(key: key, target: TranscriptTarget(
            dialect: .claude, location: TranscriptLocation(locator: .claude, reference: .id(sessionID), cwd: cwd), sessionKey: sessionID
        ))
    }
}

/// 列表預覽的對話紀錄版本：主機腳本產生(修改時間-大小 錨點)、由腳本解讀,app 只原樣帶回(#205)。
public struct PreviewVersion: Hashable, Sendable {
    public let value: String

    package init(_ value: String) {
        self.value = value
    }
}

/// 一個聊天的預覽讀取結果。
public struct PreviewReading: Sendable, Equatable {
    /// 這次讀到的範圍。
    package enum Change: String, Sendable, Equatable {
        /// 與已知版本相同，沒有傳內容。
        case unchanged
        /// 只傳已知版本之後附加的部分。
        case appended
        /// 傳整段檔尾(沒有已知版本、換檔或不能接著讀)。
        case whole
    }

    /// 主機回報的對話紀錄版本，下次當 `PreviewRequest.knownVersion` 帶回;主機沒回報時為 `nil`。
    public var version: PreviewVersion?
    package var change: Change
    /// 讀到的內容裡最後一則可讀訊息;沒變或新內容沒有可讀訊息時為 `nil`(沿用上次的預覽)。
    public var preview: MessagePreview?

    package init(version: PreviewVersion?, change: Change, preview: MessagePreview?) {
        self.version = version
        self.change = change
        self.preview = preview
    }
}

extension TranscriptReader {
    /// 列表預覽(行為規格 §4.7、R-L01):一次往返讀所有聊天的對話紀錄;帶已知版本的沒變只回 unchanged、有附加只回附加的部分(#205)。
    /// session id 或路徑不安全的請求略過。回傳 key → 讀取結果;沒有檔案、有歧義或 header 不符(Pi／OMP、Codex)的聊天不在結果裡。
    public func previewReadings(of requests: [PreviewRequest]) async throws -> [String: PreviewReading] {
        guard requests.contains(where: { TranscriptCommand.PreviewEntry($0) != nil }) else { return [:] }
        return Self.readings(of: requests, from: try await connection.readTranscriptPreviews(requests))
    }

    /// 每個聊天的原始預覽內容換成讀取結果(header 檢查、最後一則可讀訊息與進度);SSH 與 HTTPS 共用。
    package static func readings(of requests: [PreviewRequest], from bodies: [String: TranscriptPreviewBody]) -> [String: PreviewReading] {
        var readings: [String: PreviewReading] = [:]
        for request in requests {
            guard let body = bodies[request.key] else { continue }
            let lines = body.lines
            let change = body.change ?? .whole
            // 附加與沒變沿用上次整段讀取時的 header 檢查(錨點相同才算同一個檔)。
            if change == .whole {
                if let headerCheck = request.target.location.locator.headerCheck {
                    let expectedID: String? = if case .id(let id) = request.target.location.reference { id } else { nil }
                    guard headerCheck(body.header ?? [], expectedID) else { continue }
                }
            }
            // 檔尾的第一行多半被切在中間，解析時自然略過。
            var preview = change == .unchanged ? nil : Conversation.preview(of: lines.flatMap(request.target.dialect.messages(in:)))
            if preview != nil {
                let progress = AgentProgress.latest(in: lines, dialect: request.target.dialect)
                preview?.progress = progress.isEmpty ? nil : progress
            }
            readings[request.key] = PreviewReading(version: body.version, change: change, preview: preview)
        }
        return readings
    }
}

/// 預覽輸出的範圍行「key 範圍 版本」(標記之後的部分)。
private struct PreviewRangeLine {
    let key: String
    let change: PreviewReading.Change
    let version: PreviewVersion

    init?(_ fields: Substring) {
        let parts = fields.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let change = PreviewReading.Change(rawValue: parts[1]) else { return nil }
        key = parts[0]
        self.change = change
        version = PreviewVersion(parts[2])
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
        return try await connection.locateSubagent(sessionFolder: sessionFolder, callID: callID)
    }

}

extension TranscriptReader {
    /// 父對話紀錄中指名這個委派(呼叫 id 或 agent id)的行(R-W04)。內容的 checksum 與 `knownChecksum` 相同時
    /// `lines` 是 `nil`(主機只回一行)。
    public func delegationLines(path: String, callID: String, agentID: String?, knownChecksum: String?) async throws -> (checksum: String, lines: [String]?) {
        guard Self.isValidPath(path), ClaudeTranscript.isSafeDelegationID(callID),
              agentID.map(ClaudeTranscript.isSafeDelegationID) ?? true else { throw TranscriptReadError.invalidReference }
        let read = try await connection.readDelegationLines(path: path, callID: callID, agentID: agentID ?? callID, knownChecksum: knownChecksum)
        return (read.checksum, read.lines)
    }

}


/// 即時追蹤的游標與讀法(#130)。由 `TranscriptReader.follow(path:_:)` 讀一次、得到下一次的狀態。
public struct TranscriptFollow: Sendable, Equatable {
    /// 已消化的 byte 數(主機上檔案的 UTF-8 byte offset)。
    public private(set) var cursor: Int
    /// 這次可見期間已經追上主機(讀到資料，或游標等於檔案大小)。之後落後多少都分段接著讀。
    public private(set) var isLive: Bool
    /// 上次讀完後主機上還沒讀的 bytes。
    private var backlog: Int

    /// 開啟視窗後(`isLive: true`)或從快取恢復(`isLive: false`)的游標。
    public init(cursor: Int, isLive: Bool) {
        self.init(cursor: cursor, isLive: isLive, backlog: 0)
    }

    init(cursor: Int, isLive: Bool, backlog: Int) {
        self.cursor = cursor
        self.isLive = isLive
        self.backlog = max(0, backlog)
    }

    /// 畫面重新可見(回前景、重新開啟):當作重新開啟，落後太多時讀新視窗(R-B08)。
    public mutating func reopen() {
        isLive = false
        backlog = 0
    }

    /// 下一次分段追趕的上限。
    public var limit: Int {
        backlog > TranscriptReader.catchUpLimit ? TranscriptReader.catchUpBacklogLimit : TranscriptReader.catchUpLimit
    }
}

/// 追蹤讀取的結果:判讀後的尾端與主機上的檔案大小。
public struct TranscriptTailRead: Sendable, Equatable {
    public var tail: TranscriptTail
    public var size: Int

    public init(tail: TranscriptTail, size: Int) {
        self.tail = tail
        self.size = size
    }
}

/// 列表預覽時一個聊天讀到的原始內容(還沒判讀成預覽):檔尾的行、要檢查的 header、讀取範圍與版本。
/// 沒有 `change` 與 `version` 表示主機沒回報範圍(視為整段)。
public struct TranscriptPreviewBody: Sendable, Equatable {
    package var lines: [String]
    package var header: [String]?
    package var change: PreviewReading.Change?
    package var version: PreviewVersion?

    package init(lines: [String], header: [String]? = nil, change: PreviewReading.Change? = nil, version: PreviewVersion? = nil) {
        self.lines = lines
        self.header = header
        self.change = change
        self.version = version
    }
}

/// 父對話紀錄中指名某個委派的行;內容的 checksum 與已知的相同時 `lines` 是 `nil`。
public struct DelegationRead: Sendable, Equatable {
    public var checksum: String
    public var lines: [String]?

    public init(checksum: String, lines: [String]?) {
        self.checksum = checksum
        self.lines = lines
    }
}
