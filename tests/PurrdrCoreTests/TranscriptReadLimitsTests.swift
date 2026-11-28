import Foundation
import PurrdrCore
@testable import PurrdrSSH
import Testing

/// #656 點進聊天的讀取量依網路類型調整:限額(行數、位元組、補讀頁數)與它帶進各條路的指令參數。
@Suite("對話紀錄讀取限額(依網路類型)")
struct TranscriptReadLimitsTests {
    static let location = TranscriptLocation(locator: .claude, reference: .id("0000c1a0-0000-4000-8000-000000000001"), cwd: "/Users/demo/p")

    @Test("開啟讀 300 行;Wi-Fi 上限 512 KiB,行動網路 256 KiB;補讀最多 1 頁")
    func limitsPerNetwork() {
        let wifi = TranscriptReadLimits.limits(for: .wifi)
        #expect(wifi.openLines == 300)
        #expect(wifi.maxBytes == 524_288)
        #expect(wifi.emptyWindowBackfillPages == 1)
        let cellular = TranscriptReadLimits.limits(for: .cellular)
        #expect(cellular.openLines == 300)
        #expect(cellular.maxBytes == 262_144)
        #expect(cellular.emptyWindowBackfillPages == 1)
    }

    @Test("未知網路與其他網路用保守值(行動網路的量)")
    func unknownNetworkIsConservative() {
        #expect(TranscriptReadLimits.limits(for: nil) == .limits(for: .cellular))
        #expect(TranscriptReadLimits.limits(for: .other) == .limits(for: .cellular))
        #expect(TranscriptReadLimits.conservative == .limits(for: .cellular))
    }

    @Test("POSIX 的點進聊天指令與長駐通道的 open 請求帶限額")
    func commandsCarryLimits() {
        let limits = TranscriptReadLimits.limits(for: .wifi)
        let command = TranscriptCommand.open(Self.location, lines: limits.openLines, maxBytes: limits.maxBytes)
        #expect(command.hasSuffix("'300' '524288'"), "實際 \(command.suffix(80))")
        let request = TranscriptCommand.openRequest(Self.location, lines: 300, maxBytes: TranscriptReadLimits.limits(for: .cellular).maxBytes)
        #expect(request.hasPrefix("open claude 300 262144 "), "實際 \(request)")
    }

    @Test("Windows 版的點進聊天腳本收到同樣的行數與位元組參數")
    func windowsReceivesSameArguments() throws {
        let limits = TranscriptReadLimits.limits(for: .cellular)
        let command = TranscriptCommand.open(Self.location, lines: limits.openLines, maxBytes: limits.maxBytes)
        let invocation = try WindowsCommand.translate(command)
        let script = String(decoding: try #require(invocation.stdinScript), as: UTF8.self)
        #expect(script.contains("'300'"), "腳本沒有行數參數")
        #expect(script.contains("'262144'"), "腳本沒有位元組參數")
    }
}
