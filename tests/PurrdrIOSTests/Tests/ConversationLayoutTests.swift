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
    func open(
        window lines: [String], size: CGSize = CGSize(width: 390, height: 844), hitchRecorder: HitchRecorder? = nil
    ) async throws -> Mounted {
        let connection = FakeHostConnection()
        await connection.expect("session.snapshot", reply: Fixtures.data("session.snapshot.ndjson"))
        let total = Self.bytes(lines)
        await connection.answerTranscripts { request in
            switch request {
            case .locate:
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
        let content = NavigationStack { ConversationView(model: model) }.environment(\.hitchRecorder, hitchRecorder)
        // 這個 package 測試沒有 window scene(scenePhase 不是 active):要記錄器運作時明說 app 在前景。
        window.rootViewController = UIHostingController(
            rootView: hitchRecorder == nil ? AnyView(content) : AnyView(content.environment(\.scenePhase, .active)))
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

    /// 一個畫面的量測:訊息區(視窗座標 120...700pt)被「有內容的列」蓋住的高度。
    ///
    /// 不用像素取樣:這個 package 測試的 UIWindow 沒有 window scene,`drawHierarchy` 與 `layer.render` 都畫不出 UICollectionView
    /// 裡 SwiftUI 託管的列(實測整片都是空白,舊的像素量法恆量到固定的 40pt 而不受捲動位置影響,#497 的偵測因此是恆真)。
    /// 改量結構:可見的列(cell 裡真的掛了託管內容)的 frame 轉到視窗座標後蓋住訊息區多少 pt;捲到內容外或列沒排出來就是 0。
    struct Frame {
        var index: Int
        var offsetY: CGFloat
        var offsetX: CGFloat
        /// 訊息區被有內容的列蓋住的高度(pt)。
        var regionInk: Int
        var contentHeight: CGFloat
        /// 可見列比列表寬多出的寬度(pt);0 = 沒有列超出列表寬度。
        var widthOverflow: CGFloat
        var image: UIImage?
    }

    static let region = 120.0...700.0

    static func capture(_ window: UIWindow, index: Int, keepImage: Bool) -> Frame {
        window.layoutIfNeeded()
        var covered = 0.0
        var overflow: CGFloat = 0
        if let collection = findCollectionView(window) {
            overflow = collection.visibleCells.map { max(0, $0.frame.width - collection.bounds.width) }.max() ?? 0
            let intervals = collection.visibleCells
                .filter { !$0.contentView.subviews.isEmpty }
                .compactMap { cell -> ClosedRange<Double>? in
                    let frame = cell.convert(cell.bounds, to: window)
                    let low = max(frame.minY, region.lowerBound), high = min(frame.maxY, region.upperBound)
                    return high > low ? low...high : nil
                }
                .sorted { $0.lowerBound < $1.lowerBound }
            var end = -Double.infinity
            for interval in intervals {
                let start = max(interval.lowerBound, end)
                if interval.upperBound > start { covered += interval.upperBound - start }
                end = max(end, interval.upperBound)
            }
        }
        let image = keepImage ? UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) } : nil
        let scroll = findScrollView(window)
        return Frame(
            index: index, offsetY: scroll?.contentOffset.y ?? -1, offsetX: scroll?.contentOffset.x ?? -1,
            regionInk: Int(covered), contentHeight: scroll?.contentSize.height ?? -1, widthOverflow: overflow, image: image)
    }

    static func findCollectionView(_ view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView, collection.bounds.height > 300 { return collection }
        for subview in view.subviews { if let found = findCollectionView(subview) { return found } }
        return nil
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

    /// 訊息區連續空白的取樣數上限(#497):0 = 任何一個取樣畫面都不得整片空白。
    /// 依據:換成 UICollectionView 後(送出的回音不加動畫捲動、列高由 layout 在同一次排版補償)實測 80 輪長對話的送出與回覆,
    /// 每個取樣畫面(30ms 一張)訊息區都有內容,不再需要舊 LazyVStack 時代「1～2 張瞬間空白」的容差;
    /// 放寬容差會讓整片空白的回歸(例如捲到內容外)混過去。真的需要放寬時要在這裡寫新的量測依據。
    static let maximumBlankRun = 0

    /// 逐畫面的問題:水平位移不是 0(訊息貼到左邊)、訊息區連續空白超過 `maximumBlankRun` 個畫面。
    static func problems(_ frames: [Frame], requireContent: Bool = true) -> [String] {
        var found: [String] = []
        // 找不到訊息列表的捲動視圖時下面的逐畫面檢查全部略過,測試會恆真(#480 換成 UICollectionView 後確認仍量得到)。
        if !frames.contains(where: { $0.offsetY != -1 || $0.offsetX != -1 }) {
            found.append("所有畫面都找不到訊息列表的捲動視圖")
        }
        var blankRun: [Frame] = []
        func flushBlankRun() {
            if blankRun.count > maximumBlankRun, let first = blankRun.first {
                found.append("#\(first.index) 起連續 \(blankRun.count) 個畫面訊息區沒有任何內容(offsetY \(first.offsetY)、contentHeight \(first.contentHeight))")
            }
            blankRun = []
        }
        // 第一次有內容之前是載入中(對話紀錄還在讀),不算空白;有過內容之後任何一個畫面空白都算。
        var seenContent = false
        for frame in frames where frame.offsetY != -1 || frame.offsetX != -1 {
            if frame.widthOverflow > 0.5 { found.append("#\(frame.index) 有列比列表寬 \(frame.widthOverflow)pt(長段文字以理想寬度撐出畫面外)") }
            if abs(frame.offsetX) > 0.5 { found.append("#\(frame.index) 水平位移 \(frame.offsetX)(訊息貼到左邊)") }
            if frame.regionInk > 0 { seenContent = true }
            if requireContent, seenContent, frame.regionInk == 0 { blankRun.append(frame) } else { flushBlankRun() }
        }
        if requireContent, !seenContent, !frames.isEmpty { found.append("整段取樣都沒有內容") }
        flushBlankRun()
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

    /// 有空白的長英文段落(理想寬度遠大於畫面):列寬必須固定為列表寬,文字換行而不是撐出畫面外。
    static let longEnglish = String(repeating: "The export keeps dates first and quotes notes that contain commas, so spreadsheets open them cleanly. ", count: 3)

    @Test("長英文段落:列寬固定為列表寬,不被理想寬度撐出畫面外")
    func longParagraphsStayWithinListWidth() async throws {
        var mounted = try await open(window: Array(Self.lines[0...12]))
        defer { mounted.chat.cancel(); mounted.window.isHidden = true }
        try await waitForFollow(mounted)
        _ = await sample(mounted.window, frames: 10, interval: .milliseconds(30))
        await push(Self.textLine(2, Self.longEnglish), to: &mounted)
        let frames = await sample(mounted.window, frames: 40, interval: .milliseconds(30))
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
