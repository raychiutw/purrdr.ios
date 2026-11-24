import Foundation
import PurrdrAgentFeatures
import Testing
@testable import PurrdrFeatures

/// 記錄檔(背景序列佇列寫檔、大小上限、匯出)。用暫存資料夾,不碰真的 Application Support。
@Suite("卡頓記錄檔", .serialized)
struct HitchLogFileTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hitch-\(UUID().uuidString)", isDirectory: true)
    }

    static func entry(_ ms: Double) -> HitchEntry {
        .hitch(HitchEvent(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), milliseconds: ms, frames: 1, droppedFrames: 1, scroll: .dragging,
            offsetY: 0, velocityY: 0, visibleCells: 3, activity: HitchActivity(), olderLoading: false, agentWorking: false,
            system: HitchSystemState(
                thermal: "nominal", lowPower: false, reduceTransparency: false, reduceMotion: false,
                device: "d", os: "o", app: "a", textSize: "L", maxFramesPerSecond: 120)))
    }

    static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test("附加一行一筆,存成 hitch-log.jsonl;排除備份")
    func appendsJSONLines() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = HitchLogFile(directory: directory)
        file.append([Self.entry(50), Self.entry(60)])
        file.append([Self.entry(70)])
        await file.drain()

        let url = directory.appendingPathComponent("hitch-log.jsonl")
        let lines = try Self.lines(url)
        #expect(lines.count == 3)
        #expect(lines[2].contains("\"ms\":70"))
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("超過大小上限時丟最舊的行,留最新的,檔案不超過上限")
    func trimsToLimit() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oneLine = HitchLogEncoder.line(Self.entry(50)).utf8.count + 1
        let file = HitchLogFile(directory: directory, maxBytes: oneLine * 10)
        for index in 0..<40 { file.append([Self.entry(Double(100 + index))]) }
        await file.drain()

        let url = directory.appendingPathComponent("hitch-log.jsonl")
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size <= oneLine * 10)
        let lines = try Self.lines(url)
        #expect(lines.last?.contains("\"ms\":139") == true)
        #expect(lines.first?.contains("\"ms\":100") == false)
    }

    @Test("匯出:開頭一筆 meta,後面是全部記錄;沒有記錄時沒有檔案;清除後檔案消失")
    func exportsAndClears() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = HitchLogFile(directory: directory)
        let none = await file.exportFile(meta: nil)
        #expect(none == nil)

        file.append([Self.entry(50), Self.entry(60)])
        let meta = HitchEntry.meta(
            HitchSystemState(
                thermal: "fair", lowPower: true, reduceTransparency: false, reduceMotion: false,
                device: "d", os: "o", app: "a", textSize: "L", maxFramesPerSecond: 120),
            at: Date(timeIntervalSince1970: 1_800_000_000))
        let exported = try #require(await file.exportFile(meta: meta))
        let lines = try Self.lines(exported)
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"kind\":\"meta\""))

        await file.clear()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("hitch-log.jsonl").path))
        let afterClear = await file.exportFile(meta: meta)
        #expect(afterClear == nil)
    }
}
