import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Pane 終端機的大小模式(#357):預設保留電腦的 herdr 版面，手機不送 `terminal.resize`。
@MainActor
@Suite("Pane 終端機的大小模式")
struct PaneTerminalSizeModeTests {
    typealias Base = PaneTerminalModelTests

    /// 一個 `terminal.frame` 行(內容是空的)。
    static func frameLine(seq: Int, columns: Int, rows: Int, full: Bool = true) -> Data {
        Data((#"{"type":"terminal.frame","seq":\#(seq),"width":\#(columns),"height":\#(rows),"full":\#(full),"bytes":""}"# + "\n").utf8)
    }

    static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PaneTerminalSizeModeTests-\(UUID().uuidString)")!
    }

    static func bareModel(_ defaults: UserDefaults) -> PaneTerminalModel {
        PaneTerminalModel(client: PaneTerminalClient(channel: FakeHost()), paneID: "w1:p1", title: "t", defaults: defaults)
    }

    /// 靠一個輸入當「同步點」:它到了主機，前面該送的訊息也都到了。
    static func flush(_ model: PaneTerminalModel, _ host: FakeHost) async {
        model.type(Data("x".utf8))
        _ = await host.waitForStdin(ofExecution: 0, timeout: Base.timeout) { $0.stdinText.contains("\"bytes\"") }
    }

    /// 以 `native` 當電腦上 Pane 的格數開連線(保留模式在 handshake 帶它)。
    static func connect(_ host: FakeHost, mode: TerminalSizeMode, native: TerminalGridSize?, lookups: Counter = Counter()) async -> PaneTerminalModel {
        let defaults = freshDefaults()
        TerminalSizeSettings.setMode(mode, in: defaults)
        let model = PaneTerminalModel(
            client: PaneTerminalClient(channel: host), paneID: "w1:p1", title: "t", sleep: RecordingSleeper().sleep, defaults: defaults,
            nativeSize: { lookups.increment(); return native })
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Base.timeout)
        return model
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("保留模式:handshake 帶 Pane 在電腦上的格數,不是手機的格數,接上期間不送 resize")
    func keepModeHandshakesWithDesktopSize() async {
        let host = FakeHost()
        await host.expect(Base.control(columns: 133, rows: 49), reply: FakeReply(keepsOpen: true))

        let model = await Self.connect(host, mode: .keepDesktop, native: TerminalGridSize(columns: 133, rows: 49))
        await Self.flush(model, host)

        #expect(await host.unmetExpectations.isEmpty)
        #expect(await Base.sentResizes(host) == [])
        #expect(!model.keepDesktopFallback)
    }

    @Test("保留模式:讀不到電腦上的格數(電腦沒開 herdr 等)退回手機的格數,並說明")
    func keepModeFallsBackToPhoneSize() async {
        let host = FakeHost()
        await host.expect(Base.control(columns: 40, rows: 12), reply: FakeReply(keepsOpen: true))

        let model = await Self.connect(host, mode: .keepDesktop, native: nil)

        #expect(await host.unmetExpectations.isEmpty)
        #expect(model.keepDesktopFallback)
    }

    @Test("配合手機:handshake 帶手機的格數,不去查電腦上的格數")
    func fitModeIgnoresDesktopSize() async {
        let host = FakeHost()
        await host.expect(Base.control(columns: 40, rows: 12), reply: FakeReply(keepsOpen: true))
        let lookups = Counter()

        let model = await Self.connect(host, mode: .fitPhone, native: TerminalGridSize(columns: 133, rows: 49), lookups: lookups)

        #expect(await host.unmetExpectations.isEmpty)
        #expect(lookups.count == 0)
        #expect(!model.keepDesktopFallback)
    }

    @Test("預設是保留電腦版面")
    func defaultsToKeepDesktopLayout() {
        let model = Self.bareModel(Self.freshDefaults())
        #expect(model.sizeMode == .keepDesktop)
        #expect(model.keepsDesktopLayout)
    }

    @Test("保留模式:鍵盤、旋轉造成的尺寸改變都不送 terminal.resize")
    func keepModeNeverSendsResize() async {
        let host = FakeHost()
        let model = await Base.connected(host, sleep: RecordingSleeper { _ in true }.sleep, mode: .keepDesktop)

        model.viewDidResize(columns: 40, rows: 6)   // 鍵盤出現
        model.viewDidResize(columns: 80, rows: 5)   // 旋轉
        await Self.flush(model, host)

        #expect(await Base.sentResizes(host) == [])
    }

    @Test("保留模式:顯示尺寸取自 full frame,電腦端改尺寸(新的 full frame)就跟著變;增量 frame 不改")
    func displaySizeFollowsFullFrames() async {
        let host = FakeHost()
        let model = await Base.connected(host, mode: .keepDesktop)
        await host.send(.stdout(Self.frameLine(seq: 2, columns: 120, rows: 30)), toExecution: 0)
        await Base.eventually { model.displaySize == TerminalGridSize(columns: 120, rows: 30) }
        #expect(model.displaySize == TerminalGridSize(columns: 120, rows: 30))

        await host.send(.stdout(Self.frameLine(seq: 3, columns: 90, rows: 20, full: false)), toExecution: 0)
        await host.send(.stdout(Self.frameLine(seq: 4, columns: 100, rows: 24)), toExecution: 0)
        await Base.eventually { model.displaySize == TerminalGridSize(columns: 100, rows: 24) }
        #expect(model.displaySize == TerminalGridSize(columns: 100, rows: 24))
    }

    @Test("配合手機:照舊去抖送 resize")
    func fitModeStillSendsResize() async {
        let host = FakeHost()
        let model = await Base.connected(host, sleep: RecordingSleeper { _ in true }.sleep, mode: .fitPhone)
        #expect(!model.keepsDesktopLayout)

        model.viewDidResize(columns: 50, rows: 14)
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Base.timeout) { $0.stdinText.contains("terminal.resize") })
        #expect(await Base.sentResizes(host) == [[50, 14]])
    }

    @Test("保留 → 配合手機:立刻送一次手機目前的格數;配合手機 → 保留:把電腦原本的格數還回去")
    func switchingModesResizesOnce() async {
        let host = FakeHost()
        let model = await Base.connected(host, sleep: RecordingSleeper { _ in true }.sleep, mode: .keepDesktop)
        await host.send(.stdout(Self.frameLine(seq: 2, columns: 120, rows: 30)), toExecution: 0)
        await Base.eventually { model.displaySize == TerminalGridSize(columns: 120, rows: 30) }
        model.viewDidResize(columns: 44, rows: 20)

        model.setSizeMode(.fitPhone)
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Base.timeout) { $0.stdinText.contains("terminal.resize") })
        #expect(await Base.sentResizes(host) == [[44, 20]])

        model.setSizeMode(.keepDesktop)
        await Base.eventually { await Base.sentResizes(host).count == 2 }
        #expect(await Base.sentResizes(host) == [[44, 20], [120, 30]])
    }

    @Test("大小模式存在這支裝置的偏好,下次打開沿用")
    func modeIsRemembered() {
        let defaults = Self.freshDefaults()
        Self.bareModel(defaults).setSizeMode(.fitPhone)
        #expect(Self.bareModel(defaults).sizeMode == .fitPhone)
    }
}
