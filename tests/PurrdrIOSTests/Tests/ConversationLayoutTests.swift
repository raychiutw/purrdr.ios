#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import PurrdrAgentFeatures
@testable import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport

/// 聊天畫面層的版面測試(#418):把真正的 `ConversationView` 放進 `UIWindow`,逐畫面取樣。
/// 對話紀錄與主機行為用假主機連線;只量畫面層(model 層的發布順序已有測試證明沒有空白列)。
@Suite(.serialized)
@MainActor
struct ConversationLayoutTests {
    nonisolated static let paneID = "w1:p6"
    nonisolated static let sessionID = "00000000-0000-0000-0000-000000000001"
    nonisolated static let path = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"
    nonisolated static let lines = Fixtures.transcriptLines()

    nonisolated static func bytes(_ lines: some Collection<String>) -> Int { lines.reduce(0) { $0 + $1.utf8.count + 1 } }

    /// 一個 assistant text 行(新的 uuid、時間與文字)。
    nonisolated static func textLine(_ index: Int, _ text: String) -> String {
        let quoted = String(String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast())
        return #"{"type":"assistant","uuid":"00000000-0000-4000-8000-0000000c\#(String(format: "%04x", index))","timestamp":"2026-11-22T05:\#(String(format: "%02d", index % 60)):00Z","message":{"role":"assistant","content":[{"type":"text","text":\#(quoted)}]}}"#
    }

    static let longText = (1...6).map { "第 \($0) 段:這是一段比較長的回覆內容,用來讓訊息換成好幾行,檢查左右邊距是否維持 16pt、文字有沒有被裁切。" }
        .joined(separator: "\n\n")

    struct Mounted {
        let window: UIWindow
        let model: ConversationModel
        let connection: FakeHostConnection
        let chat: Task<Void, Never>
        var cursor: Int
    }

    /// 開啟一個聊天:視窗先回 `window` 行。
    func open(window lines: [String], size: CGSize = CGSize(width: 390, height: 844)) async throws -> Mounted {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        let total = Self.bytes(lines)
        await connection.answerTranscripts { request in
            switch request {
            case .locateClaude, .locate:
                return Data("\(Self.path)\n\(total)\n".utf8)
            case .window:
                return Data(("0 \(total)\n" + lines.map { "\($0.utf8.count)\t\($0)\n" }.joined()).utf8)
            case .tail(_, let cursor, _) where cursor == TranscriptReader.probeCursor:
                return Data("\(total)\n".utf8)
            default:
                throw FakeHostConnectionError.unsupported
            }
        }
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: Self.paneID,
            knownSessionID: Self.sessionID, cache: InMemoryConversationCache())
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: NavigationStack { ConversationView(model: model) })
        window.makeKeyAndVisible()
        let chat = Task { await model.run(sleep: RecordingSleeper().sleep) }
        return Mounted(window: window, model: model, connection: connection, chat: chat, cursor: total)
    }

    func waitForFollow(_ mounted: Mounted) async throws {
        for _ in 0..<2000 {
            if await mounted.connection.transcriptFollowOpenings.count == 1 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等不到追蹤開啟")
    }

    func push(_ line: String, to mounted: inout Mounted) async {
        let end = mounted.cursor + line.utf8.count + 1
        await mounted.connection.send(.appended(TranscriptChunk(start: mounted.cursor, end: end, lines: [line])), toFollow: 0)
        mounted.cursor = end
    }

    // MARK: - 取樣

    /// 一個畫面的量測:訊息區每一列像素是否有內容(與該列背景色不同)。
    struct Frame {
        var index: Int
        var inkRows: [Bool]
        var offsetY: CGFloat
        var offsetX: CGFloat
        /// 訊息區(120...700pt)有內容的列數(以 pt 計)。
        var regionInk: Int
        var contentHeight: CGFloat
        var leftInk: CGFloat    // 最左邊有內容的 x(pt)
        var image: UIImage?
    }

    static func capture(_ window: UIWindow, index: Int, keepImage: Bool) -> Frame {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        let scale = 1.0
        _ = scale
        let cg = image.cgImage!
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pointScale = CGFloat(width) / window.bounds.width
        let background = (pixels[0], pixels[1], pixels[2])
        _ = background
        var ink = [Bool](repeating: false, count: height)
        _ = ink
        var leftmost = CGFloat(width)
        // 取中間一欄(x=40..width-40)的像素與該列最左的像素比,判斷有沒有內容。
        for y in 0..<height {
            let base = (y * width + width / 2) * 4
            let ref = (Int(pixels[base]), Int(pixels[base + 1]), Int(pixels[base + 2]))
            for x in stride(from: 0, to: width, by: 2) {
                let o = (y * width + x) * 4
                let diff = abs(Int(pixels[o]) - ref.0) + abs(Int(pixels[o + 1]) - ref.1) + abs(Int(pixels[o + 2]) - ref.2)
                if diff > 60 {
                    ink[y] = true
                    if y >= Int(200 * pointScale), y < Int(650 * pointScale) { leftmost = min(leftmost, CGFloat(x)) }
                    break
                }
            }
        }
        let scroll = findScrollView(window)
        return Frame(
            index: index, inkRows: ink, offsetY: scroll?.contentOffset.y ?? -1, offsetX: scroll?.contentOffset.x ?? -1,
            regionInk: ink[Int(120 * pointScale)..<Int(700 * pointScale)].filter { $0 }.count / Int(pointScale), contentHeight: scroll?.contentSize.height ?? -1,
            leftInk: leftmost / pointScale, image: keepImage ? image : nil)
    }

    static func findScrollView(_ view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.bounds.height > 300, scroll.contentSize.height > 0,
               best == nil || scroll.bounds.height > best!.bounds.height { best = scroll }
            view.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    func sample(_ window: UIWindow, frames count: Int, startIndex: Int = 0, interval: Duration = .milliseconds(16), keepImages: Bool = false) async -> [Frame] {
        var result: [Frame] = []
        for i in 0..<count {
            result.append(Self.capture(window, index: startIndex + i, keepImage: keepImages))
            try? await Task.sleep(for: interval)
        }
        return result
    }

    /// 除錯用:設 `TEST_RUNNER_PURRDR_DUMP_FRAMES=1` 時把逐畫面截圖存到 /tmp/purrdr-418-frames。
    static func dump(_ frames: [Frame], name: String) {
        guard ProcessInfo.processInfo.environment["PURRDR_DUMP_FRAMES"] != nil else { return }
        let dir = URL(fileURLWithPath: "/private/tmp/purrdr-418-frames/\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for frame in frames {
            guard let data = frame.image?.pngData() else { continue }
            try? data.write(to: dir.appendingPathComponent(String(format: "%03d.png", frame.index)))
        }
    }

    // MARK: - 斷言

    /// 逐畫面的問題:水平位移不是 0(訊息貼到左邊)、訊息區完全沒有內容(全黑)。
    static func problems(_ frames: [Frame], requireContent: Bool = true) -> [String] {
        var found: [String] = []
        for frame in frames where frame.offsetY != -1 || frame.offsetX != -1 {
            if abs(frame.offsetX) > 0.5 { found.append("#\(frame.index) 水平位移 \(frame.offsetX)(訊息貼到左邊)") }
            if requireContent, frame.regionInk == 0 { found.append("#\(frame.index) 訊息區沒有任何內容") }
        }
        return found
    }

    @Test("開啟對話:訊息不被水平位移推到左邊,每個畫面訊息區都有內容")
    func openingKeepsContentAlignedAndVisible() async throws {
        let mounted = try await open(window: Array(Self.lines[0...12]))
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        let frames = await sample(mounted.window, frames: 60, interval: .milliseconds(30), keepImages: true)
        Self.dump(frames, name: "open")
        let problems = Self.problems(frames)
        #expect(problems.isEmpty, "\(problems.prefix(5)) 共 \(problems.count) 個畫面")
    }

    @Test("Agent 工作中新回覆進來:追加後訊息不貼左邊,每個畫面訊息區都有內容")
    func appendingKeepsContentAlignedAndVisible() async throws {
        var mounted = try await open(window: Array(Self.lines[0...12]))
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await waitForFollow(mounted)
        _ = await sample(mounted.window, frames: 20, interval: .milliseconds(30))
        await push(Self.textLine(1, Self.longText), to: &mounted)
        let frames = await sample(mounted.window, frames: 60, interval: .milliseconds(30), keepImages: true)
        Self.dump(frames, name: "append")
        let problems = Self.problems(frames)
        #expect(problems.isEmpty, "\(problems.prefix(5)) 共 \(problems.count) 個畫面")
    }

    nonisolated static func userLine(_ index: Int, _ text: String) -> String {
        let quoted = String(String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast())
        return #"{"type":"user","uuid":"00000000-0000-4000-8000-0000000d\#(String(format: "%04x", index))","timestamp":"2026-11-22T04:\#(String(format: "%02d", index % 60)):00Z","message":{"role":"user","content":\#(quoted)}}"#
    }

    /// 超過一個讀取視窗(64 KiB)的長對話:每輪一則使用者訊息與一則 Agent 回覆。
    nonisolated static let longConversation: [String] = (0..<80).flatMap { turn in
        [userLine(turn, "第 \(turn) 個問題:" + String(repeating: "請說明這一段的做法與取捨。", count: 80)),
         textLine(100 + turn, "第 \(turn) 個回覆:" + String(repeating: "這是回覆的內容,包含說明與步驟。", count: 60))]
    }

    @Test("長對話送出訊息:送出與回覆進來的每個畫面,訊息區都有內容、不貼左邊")
    func sendingInLongConversationNeverBlanksTheList() async throws {
        var mounted = try await open(window: Self.longConversation)
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await waitForFollow(mounted)
        var frames = await sample(mounted.window, frames: 20, interval: .milliseconds(30))
        await mounted.connection.expect(
            "agent.prompt",
            reply: Data(#"{"id":"purrdr:agent.prompt","result":{"type":"agent_prompted","delivery":"submitted"}}"#.utf8 + [0x0A]))
        let model = mounted.model
        model.draft = "請繼續"
        let sending = Task { await model.send() }
        frames += await sample(mounted.window, frames: 20, startIndex: 20, interval: .milliseconds(30), keepImages: true)
        await push(Self.userLine(900, "請繼續"), to: &mounted)
        frames += await sample(mounted.window, frames: 20, startIndex: 40, interval: .milliseconds(30), keepImages: true)
        await push(Self.textLine(901, "好,我繼續。" + String(repeating: "這是新的回覆內容。", count: 40)), to: &mounted)
        frames += await sample(mounted.window, frames: 30, startIndex: 60, interval: .milliseconds(30), keepImages: true)
        await sending.value
        Self.dump(frames, name: "longsend")
        let problems = Self.problems(frames)
        #expect(problems.isEmpty, "\(problems.prefix(5)) 共 \(problems.count) 個畫面")
    }
}
#endif
