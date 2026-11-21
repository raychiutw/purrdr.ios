import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 列表列的 context 百分比與待辦進度(#307):由預覽讀到的對話紀錄推得。
@MainActor
@Suite("Agent 列表進度(context 與待辦)")
struct AgentListProgressTests {
    static let todoLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"寫測試","status":"completed","activeForm":"寫測試中"},{"content":"改實作","status":"in_progress","activeForm":"改實作中"},{"content":"收尾","status":"pending","activeForm":"收尾中"}]}}]},"uuid":"a9"}"# + "\n"

    @Test("預覽讀到的最後一筆 usage:73,652 tokens 佔 200k = 37%;列的進度帶著它")
    func rowCarriesContextPercent() async throws {
        let host = try await AgentListPreviewTests.makeHost(thenSnapshots: [])
        let (model, task) = try await AgentListPreviewTests.start(host)
        defer { task.cancel() }
        try await waitUntil { await MainActor.run { model.previews["w1:p6"] != nil } }

        #expect(model.previews["w1:p6"]?.progress?.contextPercent == 37)
        let rows = AgentListProjection.sections(snapshot: model.snapshot, query: "", previews: model.previews).flatMap(\.rows)
        #expect(rows.first { $0.paneID == "w1:p6" }?.progress?.contextPercent == 37)
    }

    @Test("對話紀錄裡的 TodoWrite:列的進度有完成數與總數")
    func rowCarriesTodos() async throws {
        let host = try await AgentListPreviewTests.makeHost(thenSnapshots: [])
        let shell = await host.shell
        try shell.append(Data(Self.todoLine.utf8), to: ".claude/projects/-Users-demo-Projects-garden-journal/00000000-0000-0000-0000-000000000001.jsonl")
        let (model, task) = try await AgentListPreviewTests.start(host)
        defer { task.cancel() }
        try await waitUntil { await MainActor.run { model.previews["w1:p6"] != nil } }

        let progress = model.previews["w1:p6"]?.progress
        #expect(progress?.todoDone == 1)
        #expect(progress?.todoTotal == 3)
    }
}
