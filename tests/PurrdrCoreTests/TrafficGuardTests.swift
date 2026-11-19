import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import PurrdrSSH
import PurrdrTestSupport
import Testing

#if os(macOS)

/// 流量回歸守門(#168,spec #154):以模擬時間跑一小時，主機有 8 個 Agent,Agent 列表與聊天同時可見(iPad 三欄),
/// 聊天的 Agent 閒置與工作中各半;SSH 另開主題與註記(Claude 方案用量只在它的畫面讀，#177,不在這個情境)。斷言每台主機送出的請求種類、次數與估算位元組在上限內。
///
/// 上限是本機實測值(macOS)約 1.3 倍再取整，推算寫在各斷言旁;回歸(例如聊天畫面改回每輪讀快照)會讓請求數與位元組超出上限。
@MainActor
@Suite("流量回歸守門(一小時情境)", .serialized)
struct TrafficGuardTests {
    static let hour: Duration = .seconds(3600)
    static let chatPane = "w1:p6"
    static let otherPane = "w1:pA"
    /// 8 個 Agent(spec #154 的情境):錄製快照的 3 個，加上以 w1:pB 為樣本的 5 個;w1:pC 一直工作中，其他閒置。
    static let extraAgents = [
        "w1:pC": "00000000-0000-0000-0000-000000000004", "w1:pD": "00000000-0000-0000-0000-000000000005",
        "w1:pE": "00000000-0000-0000-0000-000000000006", "w1:pF": "00000000-0000-0000-0000-000000000007",
        "w1:pG": "00000000-0000-0000-0000-000000000008",
    ]

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
    /// 一次 keepalive(`cancel-tcpip-forward` global request 與回應，SSH 層含 MAC)的估算位元組。
    static let sshKeepaliveBytes = 160

    static let transcriptPaths = [
        "w1:p6": ".claude/projects/-Users-demo-Projects-garden-journal/00000000-0000-0000-0000-000000000001.jsonl",
        "w1:pA": ".claude/projects/-Users-demo-Projects/00000000-0000-0000-0000-000000000002.jsonl",
        "w1:pB": ".claude/projects/-Users-demo-Projects-recipe-box/00000000-0000-0000-0000-000000000003.jsonl",
    ].merging(extraAgents.mapValues { ".claude/projects/-Users-demo-Projects-recipe-box/\($0).jsonl" }) { first, _ in first }

    /// 主題、註記的主機檔案(都已同意)。
    static func writeHostFiles(to shell: LocalShellHost) throws {
        _ = try shell.write(Data("[theme]\nname = \"dracula\"\n".utf8), to: HostThemeHost.configPath.relative)
        _ = try shell.write(
            Data(#"{"sessions":[{"id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","view":{"kind":"offer","line":"Tests run in parallel","shownAt":1}}],"known":[]}"#.utf8),
            to: YouShouldKnowHost.storeDirectory.relative + "/cc-plugin-you-should-know_builtin-0123456789ab.json")
    }

    /// keepalive 照 `SSHHostChannel` 的規則估算：每 `interval` 一輪，這一輪間隔內收過主機資料就跳過，否則送一次。
    static func keepalives(inbound: [Duration], interval: Duration, over total: Duration) -> Int {
        var roundStart = Duration.zero
        var sent = 0
        while roundStart + interval <= total {
            let roundEnd = roundStart + interval
            if !inbound.contains(where: { $0 > roundStart && $0 <= roundEnd }) { sent += 1 }
            roundStart = roundEnd
        }
        return sent
    }

    @Test("SSH:一小時(閒置、工作各半，列表與聊天同時可見)的請求數與估算位元組在上限內")
    func sshHourStaysWithinBudget() async throws {
        let shell = try LocalShellHost.temporary(feedsStdin: true)
        for path in Self.transcriptPaths.values { try shell.write(Fixtures.transcript(), to: path) }
        try Self.writeHostFiles(to: shell)
        let clock = SimulatedClock()
        let statuses = ["w1:p6": "idle", "w1:pA": "working", "w1:pB": "idle", "w1:pC": "working"]
            .merging(Self.extraAgents.keys.filter { $0 != "w1:pC" }.map { ($0, "idle") }) { first, _ in first }
        let host = MeteredSSHHost(shell: shell, statuses: statuses, extraAgents: Self.extraAgents, clock: clock)
        let connection = SSHHostConnection(channel: host)
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: clock.sleep)
        let list = AgentListModel(updates: updates, transcripts: TranscriptReader(connection: connection), sleep: clock.sleep)
        let chat = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.chatPane,
            knownSessionID: nil, cache: InMemoryConversationCache(), clock: ConversationClock(now: clock.now), updates: updates,
            sleep: clock.sleep)
        let consent = InMemoryHostWriteConsentStore()
        for feature in [HostThemeHost.feature.id, YouShouldKnowFeature.id] { consent.grant(feature, host: "mac") }
        // 主題與註記共用每台主機一條長駐讀取(#203,同 `HostMember`)。
        let files = HostFiles.longRunning(channel: host)
        let theme = HostThemeModel(host: HostThemeHost(channel: host, files: files), hostID: "mac", consent: consent, sleep: clock.sleep)
        let notes = YouShouldKnowModel(host: YouShouldKnowHost(channel: host, files: files), hostID: "mac", consent: consent, sleep: clock.sleep)
        // 列表、聊天、主題各一個視窗;註記由列表與聊天輸入列共用。
        let viewers = [
            Task { await list.liveUpdates.attach() }, Task { await chat.run(sleep: clock.sleep) }, Task { await theme.liveUpdates.attach() },
            Task { await notes.liveUpdates.attach() }, Task { await notes.liveUpdates.attach() },
        ]
        defer { viewers.forEach { $0.cancel() } }
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
        viewers.forEach { $0.cancel() }
        await shell.waitUntilFinished()

        let exchanges = await host.exchanges
        let followRounds = await host.followRounds
        let pushedEvents = await host.pushedEvents
        let hostFileRounds = await host.hostFileRounds
        let counts = Dictionary(grouping: exchanges, by: \.kind).mapValues(\.count)
        var bytesByKind = Dictionary(grouping: exchanges, by: \.kind).mapValues { group in
            group.reduce(0) { $0 + $1.sent + $1.received + Self.sshChannelOverhead }
        }
        bytesByKind["transcript.follow", default: 0] += followRounds * Self.sshFollowRoundOverhead
        bytesByKind["events.subscribe", default: 0] += pushedEvents * Self.sshEventOverhead
        bytesByKind["hostFiles.follow", default: 0] += hostFileRounds.values.reduce(0) { $0 + $1.count } * Self.sshFollowRoundOverhead
        // 聊天畫面整小時可見：快速偵測斷線的間隔。
        let keepalives = Self.keepalives(
            inbound: await host.inboundTimes, interval: .nanoseconds(SSHTimeouts().quickKeepaliveInterval.nanoseconds), over: Self.hour)
        bytesByKind["keepalive"] = keepalives * Self.sshKeepaliveBytes
        let bytes = bytesByKind.values.reduce(0, +)
        Self.report(
            "SSH", counts: counts.merging(["transcript.follow 輪": followRounds, "事件": pushedEvents, "keepalive": keepalives]) { $1 },
            bytes: bytesByKind)
        // 長駐讀取每種的輪數與位元組(請求行 + 回應，不含每輪開銷;已算在 hostFiles.follow 裡)。
        print(hostFileRounds.sorted { $0.key < $1.key }.map { "  \($0.key) 輪: \($0.value.count) 次，\($0.value.bytes) B" }.joined(separator: "\n"))

        #expect(counts["session.snapshot", default: 0] <= Self.sshCaps.snapshots, "快照")
        #expect(counts["events.subscribe", default: 0] <= 2)
        #expect(counts["pane.read", default: 0] <= Self.sshCaps.paneReads, "畫面")
        #expect(counts["pane.report_metadata", default: 0] <= Self.sshCaps.presence, "在場回報")
        #expect(counts["transcript.follow", default: 0] <= 3, "追蹤：一條長駐通道")
        #expect(followRounds <= Self.sshCaps.followRounds, "追蹤輪數")
        #expect(counts["transcript.previews", default: 0] <= Self.sshCaps.previews, "預覽")
        #expect(bytesByKind["transcript.previews", default: 0] <= Self.sshPreviewBytes, "預覽位元組：帶已知版本，沒變不傳檔尾")
        #expect(counts["transcript.catchUp", default: 0] + counts["transcript.tail", default: 0] <= 2, "尾端由追蹤送來，不另外輪詢")
        #expect(counts["hostFiles.theme", default: 0] + counts["hostFiles.notes", default: 0] == 0, "主題與註記不再每次開一次性通道")
        #expect(counts["hostFiles.follow", default: 0] <= Self.sshCaps.hostFileChannels, "主機檔案：長駐通道")
        #expect(hostFileRounds["hostFiles.theme"]?.count ?? 0 <= Self.sshCaps.theme, "主題")
        #expect((hostFileRounds["hostFiles.notes"]?.count ?? 0) + counts["hostFiles.notes.locate", default: 0] <= Self.sshCaps.notes, "註記")
        #expect(bytesByKind["hostFiles.follow", default: 0] <= Self.sshCaps.hostFileBytes, "主機檔案位元組")
        #expect(keepalives <= Self.sshCaps.keepalives, "keepalive")
        #expect(counts["transcript.locate", default: 0] <= Self.sshCaps.locates, "定位：只有開聊天 1(定期更新預覽不另外問大小)")
        #expect(bytes <= Self.sshHourBudget)
    }

    /// SSH 一小時各種類的次數上限(本機實測約 1.3 倍;實測值與推算見各欄)。
    static let sshCaps = (
        // 實測 26:連上與訂閱對帳 2 + 每個狀態事件 1(23)。
        snapshots: 35,
        // 實測 324(#204 前 924):工作中每 6 秒 300 + 每段閒置找建議幾次。改回工作中每 2 秒讀會到約 924。
        paneReads: 420,
        // 實測 121:在場回報每 30 秒 120。
        presence: 160,
        // 實測 1,359:工作中每 2 秒 900 + 閒置每 4 秒 450 + 狀態變化叫醒。
        followRounds: 1_800,
        // 實測 139(#205 前 80):第一次全部 1 + 狀態變了的 Agent(23 個事件)+ 有工作中的 Agent 時每 30 秒一次。
        // 次數變多是因為不再先問大小(定位 224 → 1),每 30 秒都送一次帶已知版本的請求;位元組由 `sshPreviewBytes` 把關(少約 70%)。
        previews: 180,
        // 實測 361:每 10 秒 360(長駐通道上的請求數)。
        theme: 470,
        // 實測 362:每 10 秒 360(列表與輸入列共用一份)+ 每 10 分鐘重新定位(一次性指令)。
        notes: 480,
        // 主題與註記共用的長駐讀取通道(#203);腳本用真實時間，模擬的一小時跑不到時限，實測 1。
        hostFileChannels: 3,
        // 實測 157,772 B:722 輪，每輪請求行與回應約 135 B 加開銷 80 B。改回一次性讀取時實測 2,096,077 B(每次約 2.9 KB)。
        hostFileBytes: 205_000,
        // 實測 0:聊天畫面可見(5 秒一輪),追蹤每 2～4 秒一輪的回應讓每一輪都跳過;上限留 10 次給閒置的空檔。
        keepalives: 10,
        // 實測 1:開聊天定位一次;定期更新預覽改帶已知版本(#205),不再先問大小。
        locates: 5
    )

    /// SSH 一小時的預覽位元組上限：本機實測 1,191,753 B(#205 前 4,013,784 B)約 1.3 倍。
    /// 沒變的一次主要是指令本身(預覽腳本);改回每 30 秒讀整段檔尾會多約 3 MB。
    static let sshPreviewBytes = 1_550_000

    /// SSH 一小時的位元組上限：估算約 2.9 MB 的 1.3 倍再取整:#205 後實測 5,731,233 B,減去一次性主機檔案約 2.1 MB、
    /// 加上長駐讀取約 0.16 MB(#203 實測 157,772 B),再減去工作中少讀的畫面約 0.89 MB(#204:1,421,832 → 535,032 B);
    /// 整批 CI 印出實測後再收緊。聊天改回每輪讀快照會多約 1,350 × 6 KB ≈ 8 MB。
    static let sshHourBudget = 4_000_000

    // MARK: - HTTPS

    /// 每則 WebSocket 訊息的 frame 與 TLS record 開銷(估算;不含 TCP/IP 與 WireGuard,與 SSH 的口徑相同)。
    static let httpsMessageOverhead = 40
    /// WSS 心跳(用真實時間，不在模擬裡，照間隔推算):聊天畫面整小時可見，app 照快速偵測的間隔 ping、主機服務每 15 秒 ping,
    /// 對方各回 pong(研究報告 H3),每個控制 frame 約 35 B。
    static let httpsHeartbeats = Int(hour / HostServiceHeartbeat.quick.interval) + Int(hour / .seconds(15))
    static let httpsHeartbeatBytesPerHour = httpsHeartbeats * 2 * 35

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
        // 範例的 2 個 + 另外 6 個(FakeHostService 以範例的第一個 Agent 為樣本加上),共 8 個;w1:pC 一直工作中。
        var statuses = ["w1:p6": "idle", "w2:p1": "working", "w1:pC": "working"]
            .merging(["w1:pD", "w1:pE", "w1:pF", "w1:pG", "w1:pH"].map { ($0, "idle") }) { first, _ in first }
        let service = try await FakeHostService.start(.init(
            agentsReply: .statuses(statuses), transcriptReplies: Self.httpsTranscriptReplies))
        defer { Task { await service.stop() } }
        let clock = SimulatedClock()
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
        let updates = HostUpdates(client: HerdrClient(connection: connection), sleep: clock.sleep)
        let list = AgentListModel(updates: updates, transcripts: TranscriptReader(connection: connection))
        let chat = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.chatPane,
            knownSessionID: nil, cache: InMemoryConversationCache(), clock: ConversationClock(now: clock.now), updates: updates,
            sleep: clock.sleep)
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
        Self.report("HTTPS", counts: counts.merging(["心跳": Self.httpsHeartbeats]) { $1 }, bytes: bytesByKind)

        #expect(counts["agents.list", default: 0] <= 35, "快照：連上與訂閱對帳 2 + 每個狀態事件 1(23);實測 26")
        #expect(counts["events.subscribe", default: 0] <= 2)
        #expect(counts["transcript.follow", default: 0] <= 2, "對話紀錄由主機服務推送，只開一次追蹤")
        #expect(received.count <= 40, "app 送出的訊息：實測 31(快照 26 + 連線、訂閱、對話紀錄定位／視窗／追蹤各一),聊天畫面的輪詢不送")
        #expect(bytes <= Self.httpsHourBudget)
    }

    /// HTTPS 一小時的位元組上限：本機實測 315,545 B 約 1.3 倍再取整(推送的新增內容約 0.21 MB、`agents.list` 回應、心跳)。
    /// 聊天改回每輪讀快照會多約 1,350 × 0.65 KB ≈ 0.9 MB。
    static let httpsHourBudget = 410_000

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
