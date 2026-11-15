import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 登入 Shell 的 model:經假主機斷言開出的 PTY(`pty-req` 的格數、不帶指令 = 登入 shell)、輸入與尺寸變更。
@MainActor
@Suite("登入 Shell")
struct LoginShellModelTests {
    static let shell = PTYRequest(columns: 80, rows: 24)

    static func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 讓去抖與寫入的非同步工作跑完。
    static func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// 開好一個登入 Shell。
    static func connected(_ host: FakeHost, output: Data = Data("demo@host ~ % ".utf8)) async -> (LoginShellModel, Rendered) {
        await host.expectPTY(shell, output: output)
        let model = LoginShellModel(channel: host, title: "Studio Mac", resizeDebounce: .milliseconds(30))
        let rendered = Rendered()
        model.attach { rendered.data += $0 }
        model.viewDidResize(columns: 80, rows: 24)
        await eventually { model.status == .connected }
        return (model, rendered)
    }

    final class Rendered {
        var data = Data()
    }

    @Test("畫面回報格數後才開 PTY:pty-req 帶格數、不帶指令(登入 shell);主機的輸出畫到畫面")
    func opensLoginShellAfterSize() async throws {
        let host = FakeHost()
        await host.expectPTY(Self.shell, output: Data("demo@host ~ % ".utf8))
        let model = LoginShellModel(channel: host, title: "Studio Mac", resizeDebounce: .milliseconds(30))
        let rendered = Rendered()
        model.attach { rendered.data += $0 }

        #expect(model.status == .waitingForSize)
        #expect(await host.ptys.isEmpty)

        model.viewDidResize(columns: 80, rows: 24)
        await Self.eventually { model.status == .connected && !rendered.data.isEmpty }

        #expect(await host.ptys.map(\.request) == [Self.shell])
        #expect(model.status == .connected)
        #expect(model.statusText == "Connected")
        #expect(rendered.data == Data("demo@host ~ % ".utf8))
        #expect(model.title == "Studio Mac")
        #expect(!model.usesRemoteScroll)
    }

    @Test("尺寸改變去抖後以 window-change 送出(只送最後一次)")
    func resizesThroughWindowChange() async throws {
        let host = FakeHost()
        let (model, _) = await Self.connected(host)

        model.viewDidResize(columns: 60, rows: 20)
        model.viewDidResize(columns: 100, rows: 30)
        await Self.settle()

        #expect(await host.ptys.first?.sizes == [.init(columns: 100, rows: 30)])
    }

    @Test("鍵盤與按鍵列的輸入原樣寫進 PTY;黏著 Ctrl 讓下一個字元變成控制字元")
    func sendsInput() async throws {
        let host = FakeHost()
        let (model, _) = await Self.connected(host)

        model.type(Data("ls\r".utf8))
        model.press(.escape)
        model.toggle(.control)
        model.type(Data("c".utf8))
        await Self.settle()

        #expect(await host.ptys.first?.input == Data("ls\r".utf8) + [0x1B, 0x03])
        #expect(model.modifiers.isEmpty)
    }

    @Test("貼上：只有 shell 開了 bracketed paste 模式時才包標記")
    func pastesWithBracketsOnlyWhenRequested() async throws {
        let host = FakeHost()
        let (model, _) = await Self.connected(host)

        model.paste("echo hi", bracketed: false)
        model.paste("x", bracketed: true)
        await Self.settle()

        #expect(await host.ptys.first?.input == Data("echo hi\u{1B}[200~x\u{1B}[201~".utf8))
    }

    @Test("shell 結束：已結束，可以再開一個新的 shell")
    func shellExits() async throws {
        let host = FakeHost()
        let (model, _) = await Self.connected(host)

        await host.endPTY(0)
        await Self.eventually { model.status == .ended }

        #expect(model.status == .ended)
        #expect(model.bannerText != nil)
        #expect(model.canReconnect)
        #expect(!model.isInteractive)

        await host.expectPTY(Self.shell)
        model.reconnect()
        await Self.eventually { model.status == .connected }
        #expect(await host.ptys.count == 2)
    }

    @Test("連線中斷：顯示連線中斷並可重新連線")
    func connectionLost() async throws {
        let host = FakeHost()
        let (model, _) = await Self.connected(host)

        await host.endPTY(0, throwing: SSHConnectionError.connectionLost)
        await Self.eventually { model.status == .disconnected }

        #expect(model.status == .disconnected)
        #expect(model.statusText == "Connection Lost")
        #expect(model.canReconnect)
        #expect(!model.canTakeOver)
    }

    @Test("開不起來(例如主機拒絕):連線中斷，附上原因")
    func openFails() async throws {
        let host = FakeHost()
        let model = LoginShellModel(channel: host, title: "Studio Mac")
        model.viewDidResize(columns: 80, rows: 24)
        await Self.eventually { model.status == .disconnected }

        #expect(model.status == .disconnected)
        #expect(model.bannerText != nil)
    }

    @Test("掛斷：關閉 PTY,不自動重連")
    func hangUpClosesPTY() async throws {
        let host = FakeHost()
        let (model, _) = await Self.connected(host)

        model.hangUp()
        await Self.settle()

        #expect(await host.ptys.first?.closed == true)
        #expect(model.status == .disconnected)
        #expect(await host.ptys.count == 1)
    }
}
