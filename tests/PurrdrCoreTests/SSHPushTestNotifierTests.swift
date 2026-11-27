#if os(macOS)
import Foundation
import Network
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() { lock.withLock { continuation.take() }?.resume() }
}

/// 假的後台 `/v1/push`:記下收到的請求本文，回指定的狀態碼。
final class FakePushBackend: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var bodies: [String] = []
    private let status: Int

    var receivedBodies: [String] { lock.withLock { bodies } }
    private(set) var port: UInt16 = 0

    init(status: Int) async throws {
        self.status = status
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        // 不阻塞 cooperative thread:等 listener ready 用 continuation(多個測試並行時，用信號量會把執行緒佔光)。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                if case .ready = state { once.resume() }
            }
            listener.start(queue: .global())
        }
        port = listener.port!.rawValue
    }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            if let range = text.range(of: "\r\n\r\n"),
               let length = text.lowercased().components(separatedBy: "content-length: ").dropFirst().first.flatMap({ Int($0.prefix { $0.isNumber }) }),
               text[range.upperBound...].utf8.count >= length {
                lock.withLock { bodies.append(String(text[range.upperBound...])) }
                let response = "HTTP/1.1 \(status) X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if error == nil {
                receive(connection, buffer: buffer)
            }
        }
    }
}

/// 傳送測試通知(SSH,#328):在主機上以這支裝置的配對檔送一則推播，與外掛送出的是同一種請求。
/// 以 `LocalShellHost`(真的 `/bin/sh` 與 `curl`)執行。
@Suite("測試通知(SSH)")
struct SSHPushTestNotifierTests {
    static let deviceID = PushDeviceID(rawValue: "0123456789abcdef")!
    static let otherID = "fedcba9876543210"

    let host: LocalShellHost

    init() throws { host = try LocalShellHost.temporary() }

    func notifier(hostName: String = "Studio Mac") -> SSHPushTestNotifier {
        SSHPushTestNotifier(channel: host, deviceID: Self.deviceID, hostName: hostName)
    }

    static func fields(_ backend: FakePushBackend) throws -> [String: String] {
        let body = try #require(backend.receivedBodies.first)
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
    }

    func pair(_ id: String, endpoint: String, key: PushPairingKey = .generate()) throws -> PushPairingKey {
        let file = PushPairingFile(endpoint: URL(string: endpoint)!, key: key)
        try host.write(file.contents, to: ".purrdr/push-\(id)/pairing")
        return key
    }

    @Test("送出 key、event=test 與主機名稱(與主機服務的測試通知同一個 payload);只對這支裝置的配對")
    func sendsPluginShapedRequestForThisDeviceOnly() async throws {
        let backend = try await FakePushBackend(status: 200)
        let key = try pair("0123456789abcdef", endpoint: "http://127.0.0.1:\(backend.port)/v1/push")
        let other = try await FakePushBackend(status: 200)
        _ = try pair(Self.otherID, endpoint: "http://127.0.0.1:\(other.port)/v1/push")

        try await notifier().send()

        let bodies = backend.receivedBodies
        #expect(bodies.count == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(bodies[0].utf8)) as? [String: String])
        #expect(json == ["key": key.hex, "event": "test", "host_name": "Studio Mac"])
        #expect(other.receivedBodies.isEmpty, "不能通知這台主機上其他裝置")
        #expect(host.commands.allSatisfy { !$0.contains(key.hex) }, "密鑰不出現在指令參數")
    }

    @Test("沒有這支裝置的配對檔:notPaired,不送請求")
    func missingPairing() async throws {
        let backend = try await FakePushBackend(status: 200)
        _ = try pair(Self.otherID, endpoint: "http://127.0.0.1:\(backend.port)/v1/push")

        await #expect(throws: PushTestNotificationError.notPaired) { try await notifier().send() }
        #expect(backend.receivedBodies.isEmpty)
    }

    @Test("主機名稱含引號、反斜線、中文與 emoji:JSON 照樣有效且內容相同,指令只有 ASCII")
    func hostNameIsEscaped() async throws {
        let backend = try await FakePushBackend(status: 200)
        _ = try pair("0123456789abcdef", endpoint: "http://127.0.0.1:\(backend.port)/v1/push")
        let name = "Ray's \"Mac\" \\ 書房 \u{1F431}"

        try await notifier(hostName: name).send()

        let json = try Self.fields(backend)
        #expect(json["host_name"] == name)
        #expect(host.commands.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } })
    }

    @Test("主機名稱是空的:不帶 host_name")
    func emptyHostNameIsOmitted() async throws {
        let backend = try await FakePushBackend(status: 200)
        _ = try pair("0123456789abcdef", endpoint: "http://127.0.0.1:\(backend.port)/v1/push")

        try await notifier(hostName: "").send()

        let json = try Self.fields(backend)
        #expect(json["host_name"] == nil)
    }

    @Test("後台錯誤碼對應畫面說明的錯誤", arguments: [
        (404, PushTestNotificationError.notPaired), (403, .subscriptionRequired),
        (429, .rateLimited), (502, .apnsFailed), (500, .backendRejected(statusCode: 500)),
    ])
    func backendStatusMapsToError(status: Int, expected: PushTestNotificationError) async throws {
        let backend = try await FakePushBackend(status: status)
        _ = try pair("0123456789abcdef", endpoint: "http://127.0.0.1:\(backend.port)/v1/push")

        await #expect(throws: expected) { try await notifier().send() }
        #expect(FileManager.default.fileExists(atPath: host.url(".purrdr/push-0123456789abcdef/pairing").path), "不刪配對檔")
    }

    @Test("後台回 410(配對已撤銷):比照主機外掛，刪掉這支裝置的配對資料夾，再回 notPaired;其他裝置的配對不動")
    func revokedPairingIsDeletedOnTheHost() async throws {
        let backend = try await FakePushBackend(status: 410)
        _ = try pair("0123456789abcdef", endpoint: "http://127.0.0.1:\(backend.port)/v1/push")
        _ = try pair(Self.otherID, endpoint: "http://127.0.0.1:\(backend.port)/v1/push")

        await #expect(throws: PushTestNotificationError.notPaired) { try await notifier().send() }

        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr/push-0123456789abcdef").path), "整個配對資料夾刪掉")
        #expect(FileManager.default.fileExists(atPath: host.url(".purrdr/push-\(Self.otherID)/pairing").path))
    }

    @Test("後台錯誤碼字串與狀態碼對應一致(HTTPS 的 push_send_failed 共用)")
    func errorCodesMatchStatusCodes() {
        #expect(PushTestNotificationError(errorCode: "pairing_not_found") == .notPaired)
        #expect(PushTestNotificationError(errorCode: "pairing_revoked") == .notPaired)
        #expect(PushTestNotificationError(errorCode: "subscription_required") == .subscriptionRequired)
        #expect(PushTestNotificationError(errorCode: "rate_limited") == .rateLimited)
        #expect(PushTestNotificationError(errorCode: "daily_limit_reached") == .dailyLimitReached)
        #expect(PushTestNotificationError(errorCode: "apns_failed") == .apnsFailed)
        #expect(PushTestNotificationError(errorCode: "other") == nil)
    }

    @Test("連不上後台:backendUnreachable")
    func backendUnreachable() async throws {
        _ = try pair("0123456789abcdef", endpoint: "http://127.0.0.1:1/v1/push")

        do {
            try await notifier().send()
            Issue.record("預期丟錯")
        } catch PushTestNotificationError.backendUnreachable {
        }
    }

    @Test("Windows 主機:換成 PowerShell 版(純 ASCII、只對這支裝置的配對資料夾、payload 相同)")
    func windowsTranslation() throws {
        let command = HostFileScript.command(SSHPushTestNotifier.script, arguments: ["push-0123456789abcdef", "Studio Mac"])

        let windows = try WindowsCommand.translate(command)

        let script = String(decoding: try #require(windows.stdinScript), as: UTF8.self)
        #expect(script.utf8.allSatisfy { $0 < 128 }, "純 ASCII")
        #expect(script.contains(#""event":"test""#))
        #expect(script.contains("Invoke-WebRequest"))
        #expect(script.contains("push-0123456789abcdef"))
        #expect(script.contains("host_name"))
        #expect(script.contains("410") && script.contains("Remove-Item"), "410 時刪掉配對")
    }
}
#endif
