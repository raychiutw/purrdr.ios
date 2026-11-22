import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

#if os(macOS)

/// 流量回歸守門：圖片取檔(#225,與 `TrafficGuardTests` 同一口徑：SSH 層位元組，每條 exec 通道加固定開銷)。
///
/// 情境：聊天裡有一張 1 MiB 的截圖卡片與一張 9 MiB 的掃描檔卡片，使用者一小時內把卡片捲進畫面 20 次，
/// 中間 Agent 覆寫截圖一次。以 `LocalShellHost` 實跑取檔腳本，數通道與兩個方向的位元組。
@Suite("流量回歸守門：圖片取檔", .serialized)
struct ImageFetchTrafficGuardTests {
    /// 同 `TrafficGuardTests.sshChannelOverhead`:每條 exec 通道的固定開銷。
    static let sshChannelOverhead = 400
    /// 同 `TrafficGuardTests.sshFollowRoundOverhead`:長駐通道每輪的開銷。
    static let sshRoundOverhead = 80
    static let screenshotSize = 1024 * 1024
    static let scanSize = 9 * 1024 * 1024

    /// 記下指令、stdin 與 stdout 位元組的通道。
    actor Meter: HostChannel {
        let shell: LocalShellHost
        private(set) var channels = 0
        private(set) var sent = 0
        private(set) var received = 0
        private(set) var rounds = 0

        init(shell: LocalShellHost) { self.shell = shell }

        func execute(_ command: String) async throws -> any ExecSession {
            channels += 1
            sent += command.utf8.count
            let inner = try await shell.execute(command)
            let (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
            Task {
                do {
                    for try await event in inner.output {
                        if case .stdout(let data) = event { self.add(received: data.count) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            return MeteredSession(inner: inner, output: output, meter: self)
        }

        func openPTY(_ request: PTYRequest) async throws -> any PTYSession { throw FakeHostError.unexpectedPTY(request) }

        func add(received count: Int) { received += count }

        func add(sent data: Data) {
            sent += data.count
            rounds += data.count { $0 == 0x0A }
        }

        var bytes: Int { sent + received + channels * ImageFetchTrafficGuardTests.sshChannelOverhead + rounds * ImageFetchTrafficGuardTests.sshRoundOverhead }
    }

    struct MeteredSession: ExecSession {
        let inner: any ExecSession
        let output: AsyncThrowingStream<ExecOutput, any Error>
        let meter: Meter

        func write(_ data: Data) async throws {
            await meter.add(sent: data)
            try await inner.write(data)
        }

        func closeStdin() async { await inner.closeStdin() }
        func close() async { await inner.close() }
    }

    @Test("一小時捲進畫面 20 次、覆寫一次：截圖只傳兩次，掃描檔不自動傳;一條長駐通道")
    func screenshotsStayWithinBudget() async throws {
        let shell = try LocalShellHost.temporary(feedsStdin: true)
        let home = shell.home.path(percentEncoded: false).replacing(/\/$/, with: "")
        try shell.write(Data((0..<Self.screenshotSize).map { UInt8($0 % 253) }), to: "ledger/shot.png")
        try shell.write(Data(count: Self.scanSize), to: "ledger/scan.png")
        let meter = Meter(shell: shell)
        let loader = HostFileLoader(fetcher: SSHHostFileFetcher(channel: meter))
        let scope = HostFileAccessScope(workingDirectories: [home + "/ledger"], mentionedPaths: [])

        for appearance in 0..<20 {
            if appearance == 10 { try shell.write(Data((0..<Self.screenshotSize).map { UInt8($0 % 241) }), to: "ledger/shot.png") }
            guard case .loaded = await loader.load(home + "/ledger/shot.png", scope: scope) else { Issue.record("截圖沒有載入"); return }
            guard case .overAutomaticLimit = await loader.load(home + "/ledger/scan.png", scope: scope) else { Issue.record("掃描檔不該自動載入"); return }
        }
        let bytes = await meter.bytes
        let channels = await meter.channels
        print("流量守門 圖片取檔：通道 \(channels) 條，請求 \(await meter.rounds) 輪，估算位元組 \(bytes)")

        #expect(channels == 1, "一條長駐通道")
        // 兩次完整傳輸(base64 後 4/3)約 2.8 MB,加上 40 次查狀態與分塊請求;改成每次捲進畫面都重讀會到約 28 MB。
        #expect(bytes <= Int(Double(2 * Self.screenshotSize) * 4 / 3 * 1.1) + 60_000)
    }

    @Test("檔案卡片縮圖(#427):2 MiB 的 PDF 捲進畫面 20 次，版本沒變只傳一次內容")
    func pdfThumbnailStaysWithinBudget() async throws {
        let shell = try LocalShellHost.temporary(feedsStdin: true)
        let home = shell.home.path(percentEncoded: false).replacing(/\/$/, with: "")
        let size = 2 * 1024 * 1024
        try shell.write(Data("%PDF-1.4\n".utf8) + Data((0..<size).map { UInt8($0 % 251) }), to: "ledger/report.pdf")
        let meter = Meter(shell: shell)
        let loader = HostFileLoader(fetcher: SSHHostFileFetcher(channel: meter))
        let scope = HostFileAccessScope(workingDirectories: [home + "/ledger"], mentionedPaths: [])

        for _ in 0..<20 {
            guard case .loaded = await loader.load(home + "/ledger/report.pdf", scope: scope) else { Issue.record("PDF 沒有載入"); return }
        }
        let bytes = await meter.bytes
        let channels = await meter.channels
        print("流量守門 PDF 縮圖：通道 \(channels) 條，估算位元組 \(bytes)")

        #expect(channels == 1, "一條長駐通道")
        // 一次完整傳輸(base64 後 4/3)加 20 次查狀態;每次重讀會到約 56 MB。
        #expect(bytes <= Int(Double(size) * 4 / 3 * 1.1) + 60_000)
    }
}

#endif
