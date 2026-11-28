import Foundation
import PurrdrCore

/// SSH 的對話紀錄追蹤(#166):每台主機一條長駐通道(`LongRunningScriptChannel`)跑 `TranscriptCommand.follow`,所有追蹤中的路徑共用。
///
/// 通道結束時游標留在各追蹤裡;`unsupported` 時呼叫端退回分段接著讀的輪詢。
struct SSHTranscriptFollower: Sendable {
    /// 一個追蹤的位置：游標、主機上次回報的版本與游標前一段的錨點(不知道時是 `-`)。
    struct Position: Sendable, Equatable {
        var cursor: Int
        var stamp = TranscriptFollowProtocol.unknown
        var anchor = TranscriptFollowProtocol.unknown
    }

    enum Reply: Sendable, Equatable {
        case unchanged
        /// 版本變了;`lines` 可能是空的(只有還沒寫完的行)。`size` 是主機上的檔案大小。
        case read(size: Int, stamp: String, lines: [String], end: Int, anchor: String)
        case replaced(size: Int)
        case failed(exitCode: Int32)
        /// 點進聊天(#662):與一次性 `open` 指令相同的輸出。
        case opened(Data)
    }

    /// 點進聊天請求在長駐通道上的結果。
    enum Open: Sendable, Equatable {
        /// 與一次性 `TranscriptCommand.open` 指令的 stdout 相同。
        case output(Data)
        /// 通道忙、跑不了(Windows、Demo 主機)或這支腳本不認得請求:呼叫端改跑一次性指令。
        case unavailable
    }

    enum Poll: Sendable, Equatable {
        case reply(Reply)
        case unsupported
    }

    private let script: LongRunningScriptChannel<Reply>
    private let sleep: Sleep
    private let openState = OpenState()

    /// 點進聊天之後通道多留著的時間:接著開始的追蹤沿用同一條通道(沒有追蹤時最後關掉)。
    static let openLingerSeconds = 30

    init(
        channel: any HostChannel, command: String = TranscriptCommand.follow(), sleep: @escaping Sleep,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.sleep = sleep
        script = LongRunningScriptChannel(
            name: "transcript follow", channel: channel, command: command,
            deadline: HostCommandDeadline.transfer(bytes: TranscriptFollowProtocol.backlogLimit), sleep: sleep, closesWhenUnused: true,
            diagnostics: diagnostics, takeReply: { try Self.takeReply(from: &$0) })
    }

    /// 開始一個追蹤。
    func started() async {
        await script.started()
    }

    /// 一個追蹤結束;最後一個結束時關閉通道(腳本讀到 EOF 就結束)。
    func stopped() async {
        await script.stopped()
    }

    /// 斷線：關閉通道。等回應中的請求在新通道重問一次。
    func close() async {
        await script.close()
    }

    /// 問主機 `path` 從 `position` 之後有沒有變化。通道在回應前結束時重開再問一次。
    func poll(path: String, from position: Position) async throws -> Poll {
        let request = Data("\(position.cursor) \(position.stamp) \(position.anchor) \(path)\n".utf8)
        do {
            switch try await script.request(request) {
            case .reply(let reply): return .reply(Self.dropsStampIfCapped(reply, from: position.cursor))
            case .unsupported: return .unsupported
            }
        } catch let ended as LongRunningScriptChannel<Reply>.Ended {
            throw TranscriptReadError.failed(exitCode: ended.exitCode)
        }
    }

    /// 點進聊天(#662):在長駐通道上發一個「找對話檔 + 讀檔尾」的請求。通道忙、這支腳本跑不了(Windows 回 `error 127`)或通道連續結束時
    /// 回 `.unavailable`(之後不再試,Windows 與 Demo);主機回報的失敗(缺席、不可讀…)丟 `TranscriptReadError`。
    /// 通道原本沒開就先開,請求之後多留 `openLingerSeconds` 秒,讓接著開始的追蹤沿用它。
    func open(_ location: TranscriptLocation, lines: Int, maxBytes: Int) async throws -> Open {
        guard await !openState.isUnsupported else { return .unavailable }
        let request = Data((TranscriptCommand.openRequest(location, lines: lines, maxBytes: maxBytes) + "\n").utf8)
        let deadline = HostCommandDeadline.transfer(bytes: maxBytes > 0 ? maxBytes : TranscriptReader.defaultWindowChunkBytes)
        await script.started()
        let outcome: LongRunningScriptChannel<Reply>.Outcome?
        do {
            outcome = try await script.requestIfIdle(request, deadline: deadline)
        } catch is LongRunningScriptChannel<Reply>.Ended {
            lingerThenStop()
            return .unavailable
        } catch TranscriptReadError.changed {
            lingerThenStop()
            return .unavailable
        } catch {
            await script.stopped()
            throw error
        }
        lingerThenStop()
        switch outcome {
        case nil: return .unavailable
        case .unsupported?:
            await openState.markUnsupported()
            return .unavailable
        case .reply(.opened(let output))?: return .output(output)
        case .reply(.failed(let exitCode))?:
            if exitCode == 127 {
                await openState.markUnsupported()
                return .unavailable
            }
            throw TranscriptReadError(exitStatus: exitCode) ?? .changed
        case .reply?: return .unavailable
        }
    }

    /// 請求結束後再多留通道一段時間,之後才算這次「使用」結束。
    private func lingerThenStop() {
        Task { [script, sleep] in
            try? await sleep(.seconds(Self.openLingerSeconds))
            await script.stopped()
        }
    }

    // MARK: - 回應格式(`TranscriptFollowProtocol`)

    /// 落後超過一次讀的上限時，主機可能只讀了一部分：不留版本，否則下一輪只拿到 `unchanged`,剩下的要等檔案再變才送。
    /// 沒超過時剩下的只是還沒寫完的行，留著版本(沒變只回 `unchanged`)。
    static func dropsStampIfCapped(_ reply: Reply, from cursor: Int) -> Reply {
        guard case .read(let size, _, let lines, let end, let anchor) = reply, size - cursor > TranscriptFollowProtocol.backlogLimit else { return reply }
        return .read(size: size, stamp: TranscriptFollowProtocol.unknown, lines: lines, end: end, anchor: anchor)
    }

    /// `opened` 之後到 `openEnd <exit code>` 那行之前是一次性指令的輸出;`openEnd` 的 exit code 不是 0 是主機端的讀取失敗。
    private static func takeOpened(from buffer: inout Data, after start: Data.Index) throws -> Reply? {
        let keyword = Data("\(TranscriptCommand.openEndKeyword) ".utf8)
        var lineStart = start
        while lineStart < buffer.endIndex {
            // 第一行(定位的輸出)或視窗的行都不會以 `openEnd ` 開頭:視窗的行以數字開頭,定位輸出是路徑與大小。
            guard let lineEnd = buffer[lineStart...].firstIndex(of: 0x0A) else { return nil }
            if buffer[lineStart..<lineEnd].starts(with: keyword) {
                let code = String(decoding: buffer[lineStart..<lineEnd].dropFirst(keyword.count), as: UTF8.self)
                guard let exitCode = Int32(code) else { throw TranscriptReadError.changed }
                let output = Data(buffer[start..<lineStart])
                buffer.removeSubrange(..<buffer.index(after: lineEnd))
                return exitCode == 0 ? .opened(output) : .failed(exitCode: exitCode)
            }
            lineStart = buffer.index(after: lineEnd)
        }
        return nil
    }

    /// 從 `buffer` 取出一則完整的回應;還不完整回傳 `nil`。格式不對丟 `TranscriptReadError.changed`。
    static func takeReply(from buffer: inout Data) throws -> Reply? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let words = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).split(separator: " ").map(String.init)
        let afterHeader = buffer.index(after: newline)
        if words == [TranscriptCommand.openedKeyword] { return try takeOpened(from: &buffer, after: afterHeader) }
        switch (words.first.flatMap(TranscriptFollowProtocol.Keyword.init(rawValue:)), words.count) {
        case (.unchanged, 1):
            buffer.removeSubrange(..<afterHeader)
            return .unchanged
        case (.replaced, 2):
            guard let size = Int(words[1]) else { throw TranscriptReadError.changed }
            buffer.removeSubrange(..<afterHeader)
            return .replaced(size: size)
        case (.error, 2):
            guard let code = Int32(words[1]) else { throw TranscriptReadError.changed }
            buffer.removeSubrange(..<afterHeader)
            return .failed(exitCode: code)
        case (.appended, 3):
            // 每行紀錄以數字開頭，所以「end 」開頭的只會是結尾那行。
            let trailerPrefix = Data((TranscriptFollowProtocol.Keyword.end.rawValue + " ").utf8)
            var lineStart = afterHeader
            while let lineEnd = buffer[lineStart...].firstIndex(of: 0x0A) {
                guard buffer[lineStart..<lineEnd].starts(with: trailerPrefix) else {
                    lineStart = buffer.index(after: lineEnd)
                    continue
                }
                let trailer = String(decoding: buffer[lineStart..<lineEnd], as: UTF8.self).split(separator: " ").map(String.init)
                guard trailer.count == 3, let end = Int(trailer[1]) else { throw TranscriptReadError.changed }
                guard let size = Int(words[1]) else { throw TranscriptReadError.changed }
                let records = try TranscriptReader.records(buffer[afterHeader..<lineStart])
                buffer.removeSubrange(..<buffer.index(after: lineEnd))
                return .read(size: size, stamp: words[2], lines: records.lines, end: end, anchor: trailer[2])
            }
            return nil
        default:
            throw TranscriptReadError.changed
        }
    }
}

/// 這條通道的腳本是否認得「點進聊天」請求(Windows 與 Demo 主機不認得,只問一次)。
private actor OpenState {
    private(set) var isUnsupported = false
    func markUnsupported() { isUnsupported = true }
}
