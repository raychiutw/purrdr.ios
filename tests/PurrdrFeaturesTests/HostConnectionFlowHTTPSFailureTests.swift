import Foundation
import Network
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 一個隨便什麼請求都回固定內容的 TCP 伺服器(`reply` 為 `nil` 時接了連線卻不回應)。
final class CannedTCPServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(reply: String?) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [unowned self] connection in
            lock.withLock { connections.append(connection) }
            connection.start(queue: .global())
            guard let reply else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        ready.wait()
        port = listener.port!.rawValue
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }
}

/// 一直不回應的 HTTP 傳輸(取消時結束)。
private struct StallingHTTP: HostServiceHTTPSending {
    func post(_ url: URL, bearerToken: String?, body: Data?) async throws -> HostServiceHTTPResponse {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}

/// 回固定結果的 HTTP 傳輸。
private struct CannedHTTP: HostServiceHTTPSending {
    var respond: @Sendable () throws -> HostServiceHTTPResponse
    func post(_ url: URL, bearerToken: String?, body: Data?) async throws -> HostServiceHTTPResponse { try respond() }
}

/// #728:HTTPS 主機的連線測試要有期限，並分辨「連不到」「不是主機服務」「配對碼錯誤」。
@MainActor
@Suite("HTTPS 連線測試的失敗")
struct HostConnectionFlowHTTPSFailureTests {
    static let address = HostServiceAddress("studio.tail1234.ts.net:9443")!
    static let draft = HostConnectionDraft(name: "Studio", connection: .https(address, pairingCode: "K7QM-2XPA"))

    static let unreachableText = "This address didn’t answer. Check the address and Port. On that computer, run purrdr status to see them."
    static let notHostServiceText = "This address answered, but it isn’t Purrdr. Check the Port. On that computer, run purrdr status to see it."

    private func flow(
        http: any HostServiceHTTPSending, connections: HostServiceConnections = HostServiceConnections(),
        sleep: @escaping Sleep = RecordingSleeper().sleep
    ) -> HostConnectionFlow {
        let access = HostServiceAccess(
            tokens: InMemoryDeviceTokenStore(), pairing: HostServicePairing(http: http), deviceName: "iPhone"
        ) { address, token in
            return connections.connections.isEmpty ? FakeHostConnection() : connections.connections.removeFirst()
        }
        return HostConnectionFlow(
            store: MemoryHostStore(), credentials: HostCredentials(), hostService: access, makeChannel: ChannelFactory().make,
            sleep: sleep)
    }

    private func failedText(_ flow: HostConnectionFlow) -> String? {
        if case .failed(let message) = flow.phase { return message.text }
        return nil
    }

    @Test("配對請求一直沒有回應:15 秒期限到就離開「連線中」，說明檢查位址與 Port")
    func pairingStallEndsWithAddressMessage() async throws {
        let sleeper = RecordingSleeper(fires: { $0 == .seconds(15) })
        let flow = flow(http: StallingHTTP(), sleep: sleeper.sleep)

        await flow.test(Self.draft)

        #expect(failedText(flow) == Self.unreachableText)
        #expect(await sleeper.requested.contains(.seconds(15)))
    }

    @Test("配對成功但主機服務一直不回應 Agent 列表:期限到就失敗，說明同上")
    func snapshotStallEndsWithAddressMessage() async throws {
        let connection = await HostServiceConnections.healthy()
        await connection.hold("session.snapshot")
        let connections = HostServiceConnections()
        connections.connections = [connection]
        // 讀 Agent 列表被擋住之後期限才到(配對那一步不受影響)。
        let flow = flow(http: FakeHostServiceHTTP(), connections: connections) { _ in
            while await connection.heldCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        }

        await flow.test(Self.draft)

        #expect(failedText(flow) == Self.unreachableText)
    }

    @Test("連不到(拒絕連線、查不到名稱):同樣說明檢查位址與 Port")
    func refusedConnection() async throws {
        for error in [HostServiceError.unreachable, .hostNotFound] {
            let flow = flow(http: CannedHTTP { throw error })
            await flow.test(Self.draft)
            #expect(failedText(flow) == Self.unreachableText)
        }
    }

    @Test("連到了但不是主機服務(404、網頁、不是 JSON):說明這個 Port 不是 Purrdr")
    func notHostService() async throws {
        let bodies: [(Int, String)] = [(404, "<html>Not Found</html>"), (200, "<html>Welcome</html>"), (404, "not found")]
        for (status, body) in bodies {
            let flow = flow(http: CannedHTTP { HostServiceHTTPResponse(status: status, body: Data(body.utf8)) })
            await flow.test(Self.draft)
            #expect(failedText(flow) == Self.notHostServiceText)
        }
    }

    @Test("配對碼錯誤或過期:說明重新產生配對碼，不當成位址錯誤")
    func wrongPairingCode() async throws {
        let wrong = HostConnectionDraft(name: "Studio", connection: .https(Self.address, pairingCode: "XXXX-XXXX"))
        let flow = flow(http: FakeHostServiceHTTP())
        await flow.test(wrong)
        #expect(failedText(flow)?.contains("pairing code") == true)
        #expect(failedText(flow) != Self.unreachableText)
        #expect(failedText(flow) != Self.notHostServiceText)
    }

    @Test("失敗後可以再試一次:修好位址後從失敗回到連上")
    func retryAfterFailure() async throws {
        let connections = HostServiceConnections()
        connections.connections = [await HostServiceConnections.healthy()]
        let calls = PairCallCounter()
        let flow = flow(
            http: CannedHTTP {
                if calls.next() == 1 { throw HostServiceError.unreachable }
                return HostServiceHTTPResponse(
                    status: 200, body: Data(#"{"device_id":"d1","device_token":"token-paired","read_only":false}"#.utf8))
            }, connections: connections)

        await flow.test(Self.draft)
        #expect(failedText(flow) == Self.unreachableText)
        await flow.test(Self.draft)
        guard case .connected = flow.phase else { Issue.record("再試一次應該連上:\(flow.phase)"); return }
    }

    @Test("真的 URLSession 連到只回網頁的埠:是「不是主機服務」,不是「看不懂回應」")
    func realTransportAgainstWebPage() async throws {
        let server = try CannedTCPServer(
            reply: "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 22\r\nConnection: close\r\n\r\n<html>Not Found</html>")
        defer { server.stop() }
        let address = try #require(HostServiceAddress("http://127.0.0.1:\(server.port)"))
        let access = HostServiceAccess(tokens: InMemoryDeviceTokenStore(), deviceName: "iPhone")
        let flow = HostConnectionFlow(
            store: MemoryHostStore(), credentials: HostCredentials(), hostService: access, makeChannel: ChannelFactory().make)

        await flow.test(HostConnectionDraft(name: "X", connection: .https(address, pairingCode: "K7QM-2XPA")))

        #expect(failedText(flow) == Self.notHostServiceText)
    }
}

private final class PairCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
