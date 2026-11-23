import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// #418 第 3 項:開啟視窗(最後 40 行、64 KiB)裡全是不產生訊息的紀錄(system、api-request-blob、file-history-snapshot…)時,
/// 不能顯示「還沒有訊息」——電腦上明明有對話。要往前讀到有訊息為止;真的沒有訊息(整個檔案都沒有)才是空狀態。
@MainActor
@Suite("對話開啟視窗")
struct ConversationOpenWindowTests {
    static func systemLine(_ index: Int) -> String {
        #"{"type":"system","subtype":"turn_duration","uuid":"00000000-0000-4000-8000-0000000e\#(String(format: "%04x", index))","timestamp":"2026-11-22T05:00:00Z","durationMs":1200}"#
    }

    /// 一行超過開啟視窗位元組上限(64 KiB)、不產生訊息的 api-request-blob。
    static func blobLine(_ index: Int) -> String {
        #"{"type":"api-request-blob","sessionId":"0000c1a0-0000-4000-8000-000000000001","hash":"h\#(index)","message":{"role":"system","content":[{"type":"text","text":"\#(String(repeating: "x", count: 70_000))"}]}}"#
    }

    func openModel(tail: [String]) async throws -> ConversationModel {
        let lines = Fixtures.transcriptLines() + tail
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let setup = try ConversationModelTests.setup(transcript: data, openLines: TranscriptReader.openingLines, openMaxBytes: TranscriptReader.openingMaxBytes)
        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())
        await setup.model.poll()
        return setup.model
    }

    @Test("開啟視窗最後 40 行都不是訊息:往前讀到有訊息,不顯示空狀態")
    func windowOfOnlyNonMessageRecordsReadsEarlier() async throws {
        let model = try await openModel(tail: (0..<60).map(Self.systemLine))
        #expect(model.items.count == ConversationModelTests.fixtureItemCount, "phase=\(model.phase) older=\(model.older)")
    }

    @Test("最後幾行都是超過位元組上限的 api-request-blob:往前讀到有訊息")
    func oversizedNonMessageLastLinesReadEarlier() async throws {
        let model = try await openModel(tail: (0..<3).map(Self.blobLine))
        #expect(model.items.count == ConversationModelTests.fixtureItemCount, "phase=\(model.phase) older=\(model.older)")
    }
}
