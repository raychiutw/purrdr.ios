import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing

/// 每輪的 Pane 畫面(#559):直接打 interface,以表格驗證「這輪的需求 → 讀幾次、哪種格式」。
@MainActor
@Suite("每輪的 Pane 畫面")
struct PaneScreenRoundTests {
    /// 記錄每次讀取格式的假讀取;`failures` 是前幾次丟的錯。
    @MainActor final class Reader {
        var formats: [PaneReadFormat] = []
        var failures: [any Error] = []
        let text = "menu line\n"
        let ansi = "\u{1B}[2mdim\u{1B}[0m\r\nmenu line\r\n"

        func read(_ format: PaneReadFormat) async throws -> String {
            formats.append(format)
            if !failures.isEmpty { throw failures.removeFirst() }
            return format == .ansi ? ansi : text
        }
    }

    struct Row: CustomTestStringConvertible, Sendable {
        var name: String
        var needs: [PaneScreenRound.Need]
        var reads: [PaneReadFormat]
        var testDescription: String { name }
    }

    nonisolated static let rows: [Row] = [
        Row(
            name: "提示、面板、即時預覽、背景 agents 窗格、狀態列共用一次純文字",
            needs: [.prompt, .panel, .livePreview, .agentsPane, .statusLine, .permissionMode], reads: [.text]),
        Row(name: "建議提示詞先讀 ANSI,其餘用它去掉跳脫序列的畫面", needs: [.suggestion, .panel, .agentsPane], reads: [.ansi]),
        Row(name: "已讀過純文字就不再為建議多讀(分不出灰色),留到下一輪", needs: [.prompt, .suggestion], reads: [.text]),
        Row(
            name: "權限模式切換後的確認每次都重讀(明列的例外)",
            needs: [.permissionModeVerify, .permissionModeVerify, .permissionModeVerify], reads: [.text, .text, .text]),
        Row(name: "確認讀過的畫面也算這輪已讀", needs: [.permissionModeVerify, .panel], reads: [.text]),
        Row(name: "沒有任何需求就不讀", needs: [], reads: []),
    ]

    @Test("需求 → 讀幾次、哪種格式", arguments: rows)
    func readsPerRound(_ row: Row) async {
        let reader = Reader()
        let round = PaneScreenRound(read: { try await reader.read($0) })
        for need in row.needs { _ = await round.screen(for: need) }
        #expect(reader.formats == row.reads)
        #expect(round.readCount == row.reads.count)
    }

    @Test("新的一輪重新讀")
    func beginStartsNewRound() async {
        let reader = Reader()
        let round = PaneScreenRound(read: { try await reader.read($0) })
        _ = await round.screen(for: .prompt)
        round.begin()
        _ = await round.screen(for: .prompt)
        #expect(reader.formats == [.text, .text])
    }

    @Test("建議的 ANSI 畫面給其他需求時是去掉跳脫序列的純文字")
    func ansiServedAsPlainText() async {
        let reader = Reader()
        let round = PaneScreenRound(read: { try await reader.read($0) })
        let ansi = await round.screen(for: .suggestion)
        let plain = await round.screen(for: .panel)
        #expect(ansi == reader.ansi)
        #expect(plain == "dim\nmenu line\n")
    }

    @Test("讀不到不快取:同一輪下一個需求再試一次")
    func failureIsNotCached() async {
        let reader = Reader()
        reader.failures = [HerdrError.deadlineExceeded]
        let round = PaneScreenRound(read: { try await reader.read($0) })
        let first = await round.screen(for: .prompt)
        let second = await round.screen(for: .panel)
        #expect(first == nil)
        #expect(second == reader.text)
        #expect(reader.formats == [.text, .text])
    }

    @Test("主機服務太舊:記下說明,讀得到就拿掉")
    func updateRequiredIsReported() async {
        let reader = Reader()
        reader.failures = [HostServiceError.hostServiceUpdateRequired(.paneRead, installedVersion: "0.6.0")]
        let round = PaneScreenRound(read: { try await reader.read($0) })
        _ = await round.screen(for: .prompt)
        #expect(round.updateRequiredMessage != nil)
        _ = await round.screen(for: .prompt)
        #expect(round.updateRequiredMessage == nil)
    }

    @Test("作廢:已讀的畫面不再共用")
    func invalidateDropsScreen() async {
        let reader = Reader()
        let round = PaneScreenRound(read: { try await reader.read($0) })
        _ = await round.screen(for: .suggestion)
        round.invalidate()
        #expect(!round.hasScreen)
        _ = await round.screen(for: .panel)
        #expect(reader.formats == [.ansi, .text])
    }
}
