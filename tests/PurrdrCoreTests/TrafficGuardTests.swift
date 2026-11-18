import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import PurrdrTestSupport
import Testing

#if os(macOS)

/// 流量回歸守門(#168,spec #154):以模擬時間跑一小時，Agent 列表與聊天同時可見(iPad 三欄),
/// 聊天的 Agent 閒置與工作中各半。斷言每台主機送出的請求種類、次數與估算位元組在上限內。
///
/// 上限依實作後的設計推算(見各常數);回歸(例如聊天畫面改回每輪讀快照)會讓請求數與位元組超出上限。
@MainActor
@Suite("流量回歸守門(一小時情境)", .serialized)
struct TrafficGuardTests {
    static let hour: Duration = .seconds(3600)
    static let chatPane = "w1:p6"
    static let otherPane = "w1:pA"

    /// 情境：聊天的 Agent(w1:p6)每 5 分鐘在閒置與工作中之間切換(閒置起頭，各 30 分鐘);另一個 Agent(w1:pA)
    /// 錯開 2.5 分鐘也每 5 分鐘切換。共 23 個狀態事件，約每分鐘 0.4 個(#159 實測 0.43)。
    /// 聊天的 Agent 工作中每 10 秒寫一行對話紀錄。
    enum Action {
        case status(pane: String, String)
        case appendLine
    }

    static func timeline() -> [(at: Duration, action: Action)] {
        var actions: [(at: Duration, action: Action)] = []
        for block in 1..<12 {
            actions.append((.seconds(block * 300), .status(pane: chatPane, block.isMultiple(of: 2) ? "idle" : "working")))
        }
        for block in 0..<12 {
            actions.append((.seconds(150 + block * 300), .status(pane: otherPane, block.isMultiple(of: 2) ? "idle" : "working")))
        }
        for block in stride(from: 1, to: 12, by: 2) {
            for second in stride(from: 5, to: 300, by: 10) {
                actions.append((.seconds(block * 300 + second), .appendLine))
            }
        }
        return actions.sorted { $0.at < $1.at }
    }

    // MARK: - SSH

    /// SSH 每條 exec 通道的固定開銷(SSH 層，含加密與 MAC,不含 TCP/IP 與 WireGuard):評估報告 §4.2 實測現狀
    /// POSIX 每輪送出 1,792 B(指令 1,660 B)、收到 264 B(輸出約 10 B),扣掉內容約 390 B。
    static let sshChannelOverhead = 400
    /// 長駐追蹤通道每輪的開銷：#193 實測沒變的一輪 248 B,扣掉請求行約 150 B 與 `unchanged` 10 B。
    static let sshFollowRoundOverhead = 80
    /// 事件訂閱通道上每個事件的 SSH 封包開銷(估算)。
    static let sshEventOverhead = 40

    static let transcriptPaths = [
        "w1:p6": ".claude/projects/-Users-demo-Projects-garden-journal/00000000-0000-0000-0000-000000000001.jsonl",
        "w1:pA": ".claude/projects/-Users-demo-Projects/00000000-0000-0000-0000-000000000002.jsonl",
        "w1:pB": ".claude/projects/-Users-demo-Projects-recipe-box/00000000-0000-0000-0000-000000000003.jsonl",
    ]

    @Test("SSH:一小時(閒置、工作各半，列表與聊天同時可見)的請求數與估算位元組在上限內")
    func sshHourStaysWithinBudget() async throws {
        let shell = try LocalShellHost.temporary(feedsStdin: true)
        for path in Self.transcriptPaths.values { try shell.write(Fixtures.transcript(), to: path) }
        let host = MeteredSSHHost(shell: shell, statuses: ["w1:p6": "idle", "w1:pA": "working", "w1:pB": "idle"])
        let clock = SimulatedClock()
        let connection = SSHHostConnection(channel: host)
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: clock.sleep)
        let list = AgentListModel(updates: updates, transcripts: TranscriptReader(connection: connection))
        let chat = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.chatPane,
            knownSessionID: nil, cache: InMemoryConversationCache(), updates: updates, sleep: clock.sleep)
        let listTask = Task { await list.liveUpdates.attach() }
        let chatTask = Task { await chat.run(sleep: clock.sleep) }
        defer {
            listTask.cancel()
            chatTask.cancel()
        }
        let settle = {
            try await Self.settle {
                let inFlight = await host.inFlight
                return (inFlight, [await clock.sleepCount, await host.activity])
            }
        }
        try await waitUntil { await host.count("transcript.window") == 1 }
        try await settle()

        var lines = Fixtures.transcriptLines().makeIterator()
        for (at, action) in Self.timeline() {
            try await Self.run(until: at, clock: clock) { try await settle() }
            switch action {
            case .status(let pane, let status):
                let snapshots = await host.count("session.snapshot")
                await host.setStatus(status, of: pane)
                await host.pushStatusChanged(pane, status: status)
                try await waitUntil { await host.count("session.snapshot") > snapshots }
            case .appendLine:
                if lines.next() == nil { lines = Fixtures.transcriptLines().makeIterator() }
                let line = lines.next() ?? "{}"
                try shell.append(Data((line + "\n").utf8), to: Self.transcriptPaths[Self.chatPane]!)
            }
        }
        try await Self.run(until: Self.hour, clock: clock) { try await settle() }
        listTask.cancel()
        chatTask.cancel()
        await shell.waitUntilFinished()

        let exchanges = await host.exchanges
        let followRounds = await host.followRounds
        let pushedEvents = await host.pushedEvents
        let counts = Dictionary(grouping: exchanges, by: \.kind).mapValues(\.count)
        var bytesByKind = Dictionary(grouping: exchanges, by: \.kind).mapValues { group in
            group.reduce(0) { $0 + $1.sent + $1.received + Self.sshChannelOverhead }
        }
        bytesByKind["transcript.follow", default: 0] += followRounds * Self.sshFollowRoundOverhead
        bytesByKind["events.subscribe", default: 0] += pushedEvents * Self.sshEventOverhead
        let bytes = bytesByKind.values.reduce(0, +)
        Self.report("SSH", counts: counts.merging(["transcript.follow 輪": followRounds, "事件": pushedEvents]) { $1 }, bytes: bytesByKind)

        #expect(counts["session.snapshot", default: 0] <= 40, "快照：連上與訂閱對帳 2、聊天在訂閱前自己讀最多 2、每個狀態事件 1(23)")
        #expect(counts["events.subscribe", default: 0] <= 2)
        #expect(counts["pane.read", default: 0] <= 1_000, "畫面：工作中每 2 秒 900 + 每段閒置找建議最多 3 次")
        #expect(counts["pane.report_metadata", default: 0] <= 130, "在場回報每 30 秒")
        #expect(counts["transcript.follow", default: 0] <= 3, "追蹤：一條長駐通道")
        #expect(followRounds <= 1_500, "追蹤：工作中每 2 秒 900 + 閒置每 4 秒 450 + 狀態變化叫醒")
        #expect(counts["transcript.previews", default: 0] <= 40, "預覽：第一次全部 1 + 每個狀態事件只讀那個 Agent")
        #expect(counts["transcript.catchUp", default: 0] + counts["transcript.tail", default: 0] <= 2, "尾端由追蹤送來，不另外輪詢")
        #expect(bytes <= Self.sshHourBudget)
    }

    /// SSH 一小時的位元組上限：各種類的次數上限乘上這個情境每個請求的大小，約 4.2 MB,再取整。
    /// 畫面 1,000 × 1.54 KB、預覽 40 × 43.5 KB(錄製的對話紀錄 29 KB,檔尾最多 48 KB)、追蹤 1,500 輪 × 0.24 KB
    /// 加新增內容約 0.25 MB、快照 40 × 6 KB、在場回報 130 × 0.77 KB。聊天改回每輪讀快照會多約 1,350 × 6 KB ≈ 8 MB。
    static let sshHourBudget = 4_500_000

    // MARK: - HTTPS

    /// 每則 WebSocket 訊息的 frame 與 TLS record 開銷(估算;不含 TCP/IP 與 WireGuard,與 SSH 的口徑相同)。
    static let httpsMessageOverhead = 40
    /// WSS 心跳：兩端各每 15 秒 ping 一次、對方回 pong(研究報告 H3),每個控制 frame 約 35 B。心跳用真實時間，不在模擬裡。
    static let httpsHeartbeatBytesPerHour = 2 * 240 * 2 * 35

    static let httpsTranscriptPath = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/00000000-0000-0000-0000-000000000001.jsonl"

    /// 主機服務的對話紀錄回應：定位、視窗、追蹤都用協定範例的形狀(檔案 48,213 bytes)。
    static let httpsTranscriptReplies = [
        "transcript.locate": #"{"type":"transcript.locate.result","path":"\#(httpsTranscriptPath)","size":48213}"#,
        "transcript.window": #"{"type":"transcript.window.result","start":47950,"end":48213,"records":[{"length":118,"text":"{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"整理植物照片的標籤\"},\"uuid\":\"u1\"}"},{"length":143,"text":"{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"image\",\"source\":{\"data\":\"\"}}]},\"uuid\":\"a1\"}"}]}"#,
        "transcript.follow": #"{"type":"transcript.follow.result","size":48213,"start":48213,"records":[]}"#,
        "transcript.unfollow": #"{"type":"transcript.unfollow.result"}"#,
    ]

    @Test("HTTPS:一小時(閒置、工作各半，列表與聊天同時可見)的請求數與估算位元組在上限內")
    func httpsHourStaysWithinBudget() async throws {
        var statuses = ["w1:p6": "idle", "w2:p1": "working"]
        let service = try await FakeHostService.start(.init(
            agentsReply: .statuses(statuses), transcriptReplies: Self.httpsTranscriptReplies))
        defer { Task { await service.stop() } }
        let clock = SimulatedClock()
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: clock.sleep)
        let list = AgentListModel(updates: updates, transcripts: TranscriptReader(connection: connection))
        let chat = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.chatPane,
            knownSessionID: nil, cache: InMemoryConversationCache(), updates: updates, sleep: clock.sleep)
        let listTask = Task { await list.liveUpdates.attach() }
        let chatTask = Task { await chat.run(sleep: clock.sleep) }
        defer {
            listTask.cancel()
            chatTask.cancel()
        }
        let settle = {
            try await Self.settle { (0, [await clock.sleepCount, service.log.messages.count, service.log.sent.count]) }
        }
        try await waitUntil { !service.messages(ofType: "transcript.follow").isEmpty }
        try await settle()
        let streamID = try #require(service.messages(ofType: "transcript.follow").last?["stream_id"] as? String)

        var position = 48213
        var lines = Fixtures.transcriptLines().makeIterator()
        for (at, action) in Self.timeline() {
            try await Self.run(until: at, clock: clock) { try await settle() }
            switch action {
            case .status(let pane, let status):
                let pane = pane == Self.otherPane ? "w2:p1" : pane
                let lists = service.messages(ofType: "agents.list").count
                statuses[pane] = status
                let current = statuses
                service.update { $0.agentsReply = .statuses(current) }
                service.pushEvent("pane.agent_status_changed", paneID: pane)
                try await waitUntil { service.messages(ofType: "agents.list").count > lists }
            case .appendLine:
                if lines.next() == nil { lines = Fixtures.transcriptLines().makeIterator() }
                let line = lines.next() ?? "{}"
                let record: [String: Any] = ["length": line.utf8.count, "text": line]
                let update: [String: Any] = [
                    "type": "transcript.update", "stream_id": streamID, "start": position, "size": position + line.utf8.count + 1, "records": [record],
                ]
                position += line.utf8.count + 1
                try await service.push(String(decoding: try JSONSerialization.data(withJSONObject: update), as: UTF8.self))
            }
        }
        try await Self.run(until: Self.hour, clock: clock) { try await settle() }
        listTask.cancel()
        chatTask.cancel()

        let received = service.log.messages
        let sent = service.log.sent
        let messages = received.map { (Self.messageType($0) ?? "?", $0) } + sent.map { ("← " + (Self.messageType($0) ?? "?"), $0) }
        let counts = Dictionary(grouping: messages, by: \.0).mapValues(\.count)
        var bytesByKind = Dictionary(grouping: messages, by: \.0).mapValues { group in
            group.reduce(0) { $0 + $1.1.utf8.count + Self.httpsMessageOverhead }
        }
        bytesByKind["心跳"] = Self.httpsHeartbeatBytesPerHour
        let bytes = bytesByKind.values.reduce(0, +)
        Self.report("HTTPS", counts: counts, bytes: bytesByKind)

        #expect(counts["agents.list", default: 0] <= 40, "快照：連上與訂閱對帳 2、聊天在訂閱前自己讀最多 2、每個狀態事件 1(23)")
        #expect(counts["events.subscribe", default: 0] <= 2)
        #expect(counts["transcript.follow", default: 0] <= 2, "對話紀錄由主機服務推送，只開一次追蹤")
        #expect(received.count <= 60, "聊天畫面的輪詢不送任何訊息")
        #expect(bytes <= Self.httpsHourBudget)
    }

    /// HTTPS 一小時的位元組上限：新增的對話內容約 0.21 MB(推送)、`agents.list` 40 × 0.65 KB、心跳 34 KB,約 0.27 MB,
    /// 取 0.4 MB。聊天改回每輪讀快照會多約 1,350 × 0.65 KB ≈ 0.9 MB。
    static let httpsHourBudget = 400_000

    static func messageType(_ text: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String
    }

    // MARK: - 模擬時間

    /// 把模擬時間一步步推到 `target`:每次推到下一個到期的等待，等被測物做完再推下一步。
    static func run(until target: Duration, clock: SimulatedClock, settle: () async throws -> Void) async throws {
        while await clock.elapsed < target {
            let next = min(await clock.nextDeadline ?? target, target)
            await clock.advance(to: next)
            try await settle()
            if next >= target { break }
        }
    }

    /// 等到被測物停下來：沒有進行中的主機請求，且連續幾次檢查都沒有新的等待或請求。
    static func settle(_ probe: () async -> (inFlight: Int, signature: [Int])) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        var last: [Int] = []
        var quiet = 0
        while quiet < 3 {
            guard ContinuousClock.now < deadline else {
                Issue.record("模擬時間推進後，被測物一直沒有停下來")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
            let (inFlight, signature) = await probe()
            quiet = inFlight == 0 && signature == last ? quiet + 1 : 0
            last = signature
        }
    }

    /// 印出各種類的次數與估算位元組(CI 紀錄裡看得到，更新研究報告用)。
    static func report(_ name: String, counts: [String: Int], bytes: [String: Int]) {
        let lines = Set(counts.keys).union(bytes.keys).sorted().map { kind in
            "  \(kind): \(counts[kind].map(String.init) ?? "-") 次，\(bytes[kind].map(String.init) ?? "-") B"
        }
        print("流量守門 \(name) 一小時:\n" + lines.joined(separator: "\n") + "\n  估算位元組合計: \(bytes.values.reduce(0, +))")
    }
}

#endif
