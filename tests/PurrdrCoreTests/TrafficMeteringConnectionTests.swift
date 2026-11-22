import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import Testing

#if os(macOS)

/// 主機連線層的計量(#353):經真的 swift-nio-ssh 與真的 WebSocket 收送後，累計的位元組要對。
@Suite("流量計量:主機連線")
struct TrafficMeteringConnectionTests {
    private func meter(network: TrafficNetwork = .wifi) -> TrafficMeter {
        TrafficMeter(store: InMemoryTrafficStore(), network: network)
    }

    @Test("SSH:exec 的指令、stdin 與主機回的 stdout 都算進該主機，依目前網路類型")
    func sshExec() async throws {
        let server = try await TestSSHServer.start { _ in .echoFirstLine }
        let meter = meter(network: .cellular)
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint, traffic: meter.recorder(for: "ssh-host"))

        let command = "herdr remote-api-bridge"
        let session = try await channel.execute(command)
        try await session.write(Data("ping\n".utf8))
        var received = 0
        for try await output in session.output {
            if case .stdout(let data) = output { received += data.count }
        }
        await channel.disconnect()
        await server.stop()

        #expect(received == Data("echo:ping\n".utf8).count)
        let usage = try #require(meter.today()["ssh-host"])
        #expect(usage[.cellular] == TrafficBytes(sent: command.utf8.count + 5, received: received))
        #expect(usage[.wifi] == nil)
    }

    @Test("SSH:建立後才接上計量(attachTraffic)也會算")
    func sshAttachLater() async throws {
        let server = try await TestSSHServer.start { _ in .reply(stdout: "12345") }
        let meter = meter()
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)
        channel.attachTraffic(meter.recorder(for: "h"))
        let session = try await channel.execute("x")
        for try await _ in session.output {}
        await channel.disconnect()
        await server.stop()
        #expect(meter.today()["h"]?[.wifi]?.received == 5)
    }

    @Test("HTTPS:WebSocket 送出的訊息位元組與主機收到的相符，收到的也有算")
    func httpsWebSocket() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let meter = meter()
        let connection = HTTPSHostConnection(
            address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9", traffic: meter.recorder(for: "https-host"))

        _ = try await HerdrClient(connection: connection).snapshot()
        await connection.disconnect()

        let usage = try #require(meter.today()["https-host"]?[.wifi])
        #expect(usage.sent == service.log.messages.reduce(0) { $0 + $1.utf8.count })
        #expect(usage.received > 0)
    }

    @Test("沒接計量時照常運作")
    func noMeter() async throws {
        let service = try await FakeHostService.start()
        defer { Task { await service.stop() } }
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
        _ = try await HerdrClient(connection: connection).snapshot()
        await connection.disconnect()
    }
}

#endif
