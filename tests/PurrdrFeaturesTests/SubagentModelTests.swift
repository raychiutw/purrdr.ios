import Foundation
import PurrdrAgentFeatures
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// Subagent 畫面(行為規格 F10「Subagent 畫面」、§4.6、R-W02、R-W04)。腳本在本機對真實檔案執行(`LocalShellHost`);
/// 主對話紀錄、meta 與 subagent 對話紀錄是擷取自作者 Mac 的去識別化 fixture(`Fixtures/claude-code/`)。
@MainActor
@Suite("Subagent 畫面")
struct SubagentModelTests {
    static let session = ".claude/projects/-Users-demo-Projects-ledger/00000000-0000-0000-0000-000000000002"
    static let lines = Fixtures.transcriptLines("delegation.jsonl")
    static let agent = "agent-ad3e0000000000001"

    struct Setup {
        let shell: LocalShellHost
        let parent: String
    }

    /// 主對話紀錄放入 `parentLines`;`withSubagent` 時放好背景 agent 的 meta 與對話紀錄。
    static func setup(parentLines: [Int], withSubagent: Bool = true) throws -> Setup {
        let shell = try LocalShellHost.temporary()
        try shell.write(Data(parentLines.map { lines[$0] + "\n" }.joined().utf8), to: session + ".jsonl")
        if withSubagent { try writeSubagent(shell) }
        return Setup(shell: shell, parent: shell.home.appending(path: session + ".jsonl").path(percentEncoded: false))
    }

    static func writeSubagent(_ shell: LocalShellHost) throws {
        try shell.write(Fixtures.subagentFile(agent + ".meta.json"), to: "\(session)/subagents/\(agent).meta.json")
        try shell.write(Fixtures.subagentFile(agent + ".jsonl"), to: "\(session)/subagents/\(agent).jsonl")
    }

    static func card(_ indices: [Int]) -> SubagentCard {
        let items = Conversation.items(from: indices.map { lines[$0] }.flatMap(ClaudeTranscriptParser.messages(in:)))
        for case .subagent(let card) in items { return card }
        fatalError("沒有 subagent 卡")
    }

    @Test("依呼叫 id 找到檔案，以視窗讀出內容;subagent 的行都是 sidechain,一律顯示")
    func opensSubagentTranscript() async throws {
        let setup = try Self.setup(parentLines: [0, 1, 2])
        let model = SubagentModel(transcripts: TranscriptReader(channel: setup.shell), parentTranscript: setup.parent, card: Self.card([0, 1, 2]))

        await model.poll()

        #expect(model.phase == .ready)
        guard case .user(let bubble) = model.items.first else {
            Issue.record("第一列應是 subagent 收到的指示")
            return
        }
        #expect(bubble.text == "Compare the two CSV libraries we are considering and recommend one.")
        #expect(model.items.count == 2)
        #expect(model.title == "Compare two CSV parsing libraries")
        #expect(model.subtitle == "general-purpose")
    }

    /// #130:subagent 一次寫出超過 64 KiB 時，畫面上原有的訊息留著，新訊息接在後面(不改讀新視窗取代)。
    @Test("大量輸出：一次寫入超過 64 KiB 時，原有訊息還在，新訊息依序接在後面")
    func largeWriteKeepsShownMessages() async throws {
        let setup = try Self.setup(parentLines: [0, 1, 2])
        let model = SubagentModel(transcripts: TranscriptReader(channel: setup.shell), parentTranscript: setup.parent, card: Self.card([0, 1, 2]), openLines: 3)
        await model.poll()
        let before = model.items.map(\.id)

        // 以 subagent 收到的指示(第一行)為底，換掉 uuid 與內容。
        let first = String(decoding: Fixtures.subagentFile(Self.agent + ".jsonl"), as: UTF8.self).split(separator: "\n")[0]
        let added = (1...5).map { number in
            first.replacingOccurrences(of: "00000000-0000-4000-9000-000000000018", with: "00000000-0000-4000-9000-0000000b000\(number)")
                .replacingOccurrences(of: "Compare the two CSV libraries we are considering and recommend one.",
                                      with: "第 \(number) 段" + String(repeating: "很長的輸出", count: 1400))
        }
        try setup.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: "\(Self.session)/subagents/\(Self.agent).jsonl")
        await model.poll()

        #expect(Array(model.items.map(\.id).prefix(before.count)) == before)
        #expect(model.items.count == before.count + 5)
    }

    /// #130 review 2:畫面重新可見(`run()` 開始時 `reopen()`)當作重新開啟：離開期間落後超過 64 KiB 就讀新視窗，
    /// 不逐段重播積壓(R-B08)。
    @Test("重新可見：離開期間落後超過 64 KiB,回來後讀新視窗")
    func reopenFarBehindReadsNewWindow() async throws {
        let setup = try Self.setup(parentLines: [0, 1, 2])
        let model = SubagentModel(transcripts: TranscriptReader(channel: setup.shell), parentTranscript: setup.parent, card: Self.card([0, 1, 2]), openLines: 3)
        await model.poll()
        let before = model.items.map(\.id)

        let first = String(decoding: Fixtures.subagentFile(Self.agent + ".jsonl"), as: UTF8.self).split(separator: "\n")[0]
        let added = (1...5).map { number in
            first.replacingOccurrences(of: "00000000-0000-4000-9000-000000000018", with: "00000000-0000-4000-9000-0000000b000\(number)")
                .replacingOccurrences(of: "Compare the two CSV libraries we are considering and recommend one.",
                                      with: "第 \(number) 段" + String(repeating: "很長的輸出", count: 1400))
        }
        try setup.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: "\(Self.session)/subagents/\(Self.agent).jsonl")
        model.reopen()
        await model.poll()

        #expect(model.items.count == 3, "新視窗只有最後 3 行")
        #expect(Set(model.items.map(\.id)).isDisjoint(with: before))
    }

    @Test("執行中找不到是「啟動中」,之後再找到;結束後找不到是「不在這台主機」")
    func startingThenFound() async throws {
        let running = try Self.setup(parentLines: [0, 1], withSubagent: false)
        let model = SubagentModel(transcripts: TranscriptReader(channel: running.shell), parentTranscript: running.parent, card: Self.card([0, 1]))
        await model.poll()
        #expect(model.phase == .starting)

        try Self.writeSubagent(running.shell)
        await model.poll()
        #expect(model.phase == .ready)

        let ended = try Self.setup(parentLines: [0, 1, 2], withSubagent: false)
        let done = SubagentModel(transcripts: TranscriptReader(channel: ended.shell), parentTranscript: ended.parent, card: Self.card([0, 1, 2]))
        await done.poll()
        #expect(done.phase == .notOnHost)
    }

    /// R-W04:父聊天被蓋住時停止輪詢，卡片學不到結束，所以畫面自己去父對話紀錄找。
    @Test("結束偵測：執行中時在父對話紀錄找指名此呼叫／agent 的行，用和卡片相同的規則判斷")
    func detectsEndFromParentTranscript() async throws {
        let setup = try Self.setup(parentLines: [0, 1])
        let model = SubagentModel(transcripts: TranscriptReader(channel: setup.shell), parentTranscript: setup.parent, card: Self.card([0, 1]))

        await model.checkEnd()
        #expect(model.status == .running)

        try setup.shell.append(Data((Self.lines[2] + "\n").utf8), to: Self.session + ".jsonl")
        await model.checkEnd()
        #expect(model.status == .completed)
    }

    @Test("workflow 裡的 agent:直接以 run id 與 agent id 組出的路徑讀")
    func workflowAgentByPath() async throws {
        let shell = try LocalShellHost.temporary()
        try shell.write(Fixtures.subagentFile(Self.agent + ".jsonl"), to: "\(Self.session)/subagents/workflows/wf_demo01/agent-aw0000000000000001.jsonl")
        let folder = shell.home.appending(path: Self.session).path(percentEncoded: false)
        let path = try #require(ClaudeTranscript.workflowAgentTranscript(sessionFolder: folder, runID: "wf_demo01", agentID: "aw0000000000000001"))
        let model = SubagentModel(transcripts: TranscriptReader(channel: shell), transcriptPath: path, title: "links", subtitle: nil, status: .completed)

        await model.poll()

        #expect(model.phase == .ready)
        #expect(model.items.count == 2)
    }

    @Test("箭頭：還沒有 session 資料夾(對話紀錄未定位)或卡片沒有呼叫 id 時不能開;workflow 卡與畫面共用同一個進度 model")
    func openingRequiresFolderAndCallID() async throws {
        let setup = try ConversationModelTests.setup(transcript: Fixtures.transcript("delegation.jsonl"))
        let card = Self.card([0, 1])
        #expect(setup.model.subagentModel(for: card) == nil)

        await setup.host.bridge.expect(ConversationModelTests.bridge, reply: ConversationModelTests.snapshot())
        await setup.model.poll()

        #expect(setup.model.subagentModel(for: card) != nil)
        var noCall = card
        noCall.callID = nil
        #expect(setup.model.subagentModel(for: noCall) == nil)

        let workflow = WorkflowCard(id: "w", callID: "toolu_demo_w1", name: "release-review", runID: "wf_demo01")
        let first = try #require(setup.model.workflowModel(for: workflow))
        #expect(setup.model.workflowModel(for: workflow) === first)
    }

    @Test("HTTPS 主機的主機服務太舊：顯示需要更新主機服務，不再找檔案")
    func outdatedHostServiceShowsUpdateNeeded() async throws {
        let connection = FakeHostConnection()
        await connection.answerTranscripts { _ in
            throw HostServiceError.hostServiceUpdateRequired(.transcriptPreviewsAndDelegations, installedVersion: "0.6.2")
        }
        let model = SubagentModel(
            transcripts: TranscriptReader(connection: connection), parentTranscript: "/Users/demo/s.jsonl", card: Self.card([0, 1]))

        await model.poll()

        guard case .unavailable(let reason) = model.phase else {
            Issue.record("expected unavailable, got \(model.phase)")
            return
        }
        #expect(reason.contains("0.6.2"))
    }
}
