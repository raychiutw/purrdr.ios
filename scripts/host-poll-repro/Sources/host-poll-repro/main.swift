// 主機並行輪詢的回歸工具：照 app 的對話畫面一次輪詢的主機指令順序(snapshot → 讀畫面 → 定位 → 視窗 → 追蹤),
// 由 WORKERS 個畫面同時輪詢，旁邊開著 SUBSCRIPTIONS 個事件訂閱。只執行唯讀指令。
//
// 每一步上限 STEP_LIMIT 秒：到了就取消，取消後 CANCEL_GRACE 秒內還沒返回記為卡住(HUNG)。
// 全部成功印 GREEN、exit 0;任何一步失敗或卡住印 RED、exit 1。
//
// 環境變數:PURRDR_REPRO_HOST(user@host[:port])、PURRDR_REPRO_KEY(OpenSSH 私鑰路徑)、
// PURRDR_REPRO_HOST_KEY(主機公鑰檔，`ssh-keyscan` 的一行)、ROUNDS、SUBSCRIPTIONS、WORKERS、STEP_LIMIT、CANCEL_GRACE。
import Foundation
import PurrdrCore

func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let environment = ProcessInfo.processInfo.environment
func setting(_ name: String, default value: String? = nil) -> String {
    guard let found = environment[name] ?? value else {
        log("缺少環境變數 \(name)")
        exit(2)
    }
    return found
}

let rounds = Int(setting("ROUNDS", default: "1"))!
let subscriptionCount = Int(setting("SUBSCRIPTIONS", default: "2"))!
let workerCount = Int(setting("WORKERS", default: "4"))!
let stepLimit = Double(setting("STEP_LIMIT", default: "45"))!
let cancelGrace = Double(setting("CANCEL_GRACE", default: "2"))!

let destination = setting("PURRDR_REPRO_HOST")
let userAndHost = destination.split(separator: "@", maxSplits: 1).map(String.init)
let hostAndPort = userAndHost[1].split(separator: ":").map(String.init)
let endpoint = SSHEndpoint(host: hostAndPort[0], port: hostAndPort.count > 1 ? Int(hostAndPort[1])! : 22, username: userAndHost[0])
let privateKeyText = try String(contentsOfFile: setting("PURRDR_REPRO_KEY"), encoding: .utf8)
let hostKeyLine = try String(contentsOfFile: setting("PURRDR_REPRO_HOST_KEY"), encoding: .utf8)
    .split(separator: "\n").first { !$0.hasPrefix("#") }.map(String.init) ?? ""
// ssh-keyscan 的格式是「主機 類型 公鑰」;HostKeyFingerprint 要「類型 公鑰」。
let hostKeyFields = hostKeyLine.split(separator: " ")
let hostPublicKey = hostKeyFields.first.map { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") } == true
    ? hostKeyLine : hostKeyFields.dropFirst().joined(separator: " ")

let ssh = SSHHostChannel(
    endpoint: endpoint, hostKeyPin: try HostKeyFingerprint(openSSHPublicKey: hostPublicKey),
    credential: { .privateKey(try SSHPrivateKey(openSSH: privateKeyText)) })

/// 一步的結果。
enum StepOutcome: Sendable {
    case ok
    case failed(String)
    /// 上限到了，取消後也沒有在寬限內返回。
    case hung
}

actor Report {
    private(set) var failures: [String] = []
    private(set) var hung: [String] = []
    private var inflight: [Int: (name: String, start: Date)] = [:]
    private var nextID = 0
    let started = Date()

    func begin(_ name: String) -> Int {
        nextID += 1
        inflight[nextID] = (name, Date())
        return nextID
    }

    func end(_ id: Int, _ outcome: StepOutcome) {
        guard let entry = inflight.removeValue(forKey: id) else { return }
        let elapsed = Date().timeIntervalSince(entry.start)
        let at = entry.start.timeIntervalSince(started)
        switch outcome {
        case .ok:
            log(String(format: "  %@ @%.1f %.1fs ok", entry.name, at, elapsed))
        case .failed(let reason):
            failures.append(entry.name)
            log(String(format: "  %@ @%.1f %.1fs FAIL %@", entry.name, at, elapsed, reason))
        case .hung:
            hung.append(entry.name)
            log(String(format: "  %@ @%.1f %.1fs HUNG(取消後 %.0f 秒內沒有返回)", entry.name, at, elapsed, cancelGrace))
        }
    }

    func stillWaiting(longerThan seconds: Double) -> [(String, Double)] {
        inflight.values.map { ($0.name, Date().timeIntervalSince($0.start)) }.filter { $0.1 > seconds }
    }
}

let report = Report()

final class Slot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?
    var value: Result<Value, any Error>? { lock.withLock { stored } }
    func set(_ result: Result<Value, any Error>) { lock.withLock { stored = result } }
}

/// 在上限內執行 `body`;上限到了取消它，取消也不返回時記為卡住並放著不等(app 畫面離開時就是這樣)。
func step<Value: Sendable>(_ name: String, _ body: @escaping @Sendable () async throws -> Value) async -> Value? {
    let id = await report.begin(name)
    let slot = Slot<Value>()
    let task = Task {
        do {
            slot.set(.success(try await body()))
        } catch {
            slot.set(.failure(error))
        }
    }
    func wait(seconds: Double) async -> Result<Value, any Error>? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let result = slot.value { return result }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return slot.value
    }
    var result = await wait(seconds: stepLimit)
    if result == nil {
        task.cancel()
        result = await wait(seconds: cancelGrace)
        guard result != nil else {
            await report.end(id, .hung)
            return nil
        }
        await report.end(id, .failed("超過 \(Int(stepLimit)) 秒，已取消"))
        return nil
    }
    switch result {
    case .success(let value)?:
        await report.end(id, .ok)
        return value
    case .failure(let error)?:
        await report.end(id, .failed("\(error)"))
        return nil
    case nil:
        return nil
    }
}

guard let operatingSystem = await step("偵測作業系統", { try await HostOperatingSystem.detect(on: ssh) }) else {
    log("RED 連不上主機")
    exit(1)
}
let channel = operatingSystem.channel(ssh)
let client = HerdrClient(channel: channel)
let transcripts = TranscriptReader(channel: channel)
log("主機作業系統：\(operatingSystem)")

var subscriptions: [AsyncThrowingStream<HerdrEvent, any Error>] = []
for index in 0..<subscriptionCount {
    if let stream = await step("訂閱#\(index)", { try await client.subscribe(EventSubscription.hostWide) }) { subscriptions.append(stream) }
}

let watchdog = Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(10))
        for (name, seconds) in await report.stillWaiting(longerThan: 10) {
            log(String(format: "WATCHDOG 已等 %.0f 秒：%@", seconds, name))
        }
    }
}

func poll(worker: Int) async {
    for round in 1...rounds {
        log("畫面\(worker) 第 \(round) 輪")
        guard let snapshot = await step("snapshot", { try await client.snapshot() }) else { continue }
        for agent in snapshot.agents {
            guard let target = agent.transcriptTarget else { continue }
            _ = await step("讀畫面 \(agent.paneID)", { try await client.readPane(paneID: agent.paneID) })
            guard let located = await step("定位 \(agent.paneID)", { try await transcripts.locate(target) }) else { continue }
            guard let chunk = await step("視窗 \(agent.paneID)(\(located.size)B)", {
                try await transcripts.window(path: located.path, endingAt: located.size, lines: 200)
            }) else { continue }
            _ = await step("追蹤 \(agent.paneID)", { try await transcripts.tail(path: located.path, from: chunk.end) })
        }
    }
}

await withTaskGroup(of: Void.self) { group in
    for worker in 1...workerCount { group.addTask { await poll(worker: worker) } }
}
watchdog.cancel()
_ = subscriptions
let failures = await report.failures
let hung = await report.hung
log(String(format: "所有畫面輪詢結束 @%.1f", Date().timeIntervalSince(report.started)))
log(failures.isEmpty && hung.isEmpty ? "GREEN" : "RED failures=\(failures.count) hung=\(hung.count)")
// 卡住的 task 還掛在連線上：不等 disconnect,直接結束。
exit(failures.isEmpty && hung.isEmpty ? 0 : 1)
