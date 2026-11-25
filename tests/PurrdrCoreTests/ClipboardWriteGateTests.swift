import Foundation
import PurrdrCore
import Testing

/// 主機經 OSC 52 要寫剪貼簿時，要先問使用者，允許才寫(#578)。
@Suite("主機要寫剪貼簿先問")
struct ClipboardWriteGateTests {
    private final class RecordingClipboard: LocalClipboardWriting {
        var writes: [String] = []
        func write(_ text: String) { writes.append(text) }
    }

    @Test("收到請求只先待確認，不寫剪貼簿")
    func receiveDoesNotWrite() {
        let clipboard = RecordingClipboard()
        var gate = ClipboardWriteGate()

        gate.receive(Data("hello".utf8))

        #expect(gate.hasPendingRequest)
        #expect(clipboard.writes.isEmpty)
    }

    @Test("允許才寫，寫一次，之後沒有待確認")
    func allowWritesOnce() {
        let clipboard = RecordingClipboard()
        var gate = ClipboardWriteGate()
        gate.receive(Data("hello".utf8))

        gate.allow(into: clipboard)
        gate.allow(into: clipboard)

        #expect(clipboard.writes == ["hello"])
        #expect(!gate.hasPendingRequest)
    }

    @Test("拒絕不寫")
    func denyDoesNotWrite() {
        let clipboard = RecordingClipboard()
        var gate = ClipboardWriteGate()
        gate.receive(Data("hello".utf8))

        gate.deny()
        gate.allow(into: clipboard)

        #expect(clipboard.writes.isEmpty)
        #expect(!gate.hasPendingRequest)
    }

    @Test("連續多次請求只保留最新一筆")
    func latestRequestWins() {
        let clipboard = RecordingClipboard()
        var gate = ClipboardWriteGate()
        gate.receive(Data("first".utf8))
        gate.receive(Data("second".utf8))

        gate.allow(into: clipboard)

        #expect(clipboard.writes == ["second"])
    }

    @Test("不是合法 UTF-8 或空內容的請求直接忽略，也不蓋掉待確認的")
    func invalidOrEmptyIgnored() {
        let clipboard = RecordingClipboard()
        var gate = ClipboardWriteGate()

        gate.receive(Data([0xFF, 0xFE]))
        gate.receive(Data())
        #expect(!gate.hasPendingRequest)

        gate.receive(Data("keep".utf8))
        gate.receive(Data([0xFF]))
        gate.allow(into: clipboard)

        #expect(clipboard.writes == ["keep"])
    }
}
