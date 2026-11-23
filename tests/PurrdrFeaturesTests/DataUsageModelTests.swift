#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import Testing

/// 數據用量頁的 model(#354,spec #337):摘要、期間、分類、主機過濾與目前主機。
@MainActor
@Suite("數據用量頁")
struct DataUsageModelTests {
    static let mac = HostSelection.host(UUID(uuidString: "6F1C2A4E-0B7D-4C1E-9A55-0D2C8E1F3A10")!)
    static let linux = HostSelection.host(UUID(uuidString: "1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C8D")!)
    static let deleted = "9E9E9E9E-0000-4000-8000-000000000001"
    static let options = [HostOption(id: mac, name: "Mac"), HostOption(id: linux, name: "Linux")]

    final class Clock: @unchecked Sendable {
        var now = ISO8601DateFormatter().date(from: "2026-11-21T10:00:00+08:00")!
    }

    let clock = Clock()
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()
    let store = InMemoryTrafficStore()

    func meter() -> TrafficMeter {
        TrafficMeter(store: store, now: { [clock] in clock.now }, calendar: calendar, network: .wifi)
    }

    func model(
        _ meter: TrafficMeter, currentHost: HostSelection? = nil
    ) -> DataUsageModel {
        DataUsageModel(
            meter: meter, hosts: Self.options, currentHost: currentHost,
            now: { [clock] in clock.now }, calendar: calendar)
    }

    static func hostID(_ host: HostSelection) -> String { host.storedValue }

    @Test("摘要：這次開啟與今天的總量與行動網路，加總送出與收到")
    func summaryTotalsAndCellular() {
        let meter = meter()
        let mac = Self.hostID(Self.mac)
        meter.record(hostID: mac, direction: .received, bytes: 4_000)
        meter.record(hostID: mac, direction: .sent, bytes: 1_000)
        meter.setNetwork(.cellular)
        meter.record(hostID: mac, direction: .received, bytes: 500)
        let model = model(meter)
        #expect(model.sinceLaunch == DataUsageSummary(total: 5_500, cellular: 500))
        #expect(model.today == DataUsageSummary(total: 5_500, cellular: 500))
    }

    @Test("這次開啟只在記憶體:重新建立 meter 後從頭算，今天仍保留")
    func sinceLaunchResetsOnRelaunch() {
        let first = meter()
        first.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 900)
        first.flush()
        let model = model(meter())
        #expect(model.sinceLaunch == DataUsageSummary(total: 0, cellular: 0))
        #expect(model.today.total == 900)
    }

    @Test("預設是所有主機:摘要加總全部主機;選一台只算那台")
    func hostFilter() {
        let meter = meter()
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 300)
        meter.record(hostID: Self.hostID(Self.linux), direction: .received, bytes: 70)
        let model = model(meter)
        #expect(model.host == nil)
        #expect(model.today.total == 370)
        model.selectHost(Self.linux)
        #expect(model.today.total == 70)
        #expect(model.sinceLaunch.total == 70)
    }

    @Test("有目前主機就顯示那台;在這裡改主機與改回所有主機只改自己的選取")
    func currentHostIsOnlyTheInitialSelection() {
        let model = model(meter(), currentHost: Self.mac)
        #expect(model.host == Self.mac)
        model.selectHost(Self.linux)
        #expect(model.host == Self.linux)
        model.selectHost(nil)
        #expect(model.host == nil)
    }

    @Test("目前主機已不在主機清單時當作所有主機")
    func unknownCurrentHost() {
        let model = model(meter(), currentHost: .host(UUID()))
        #expect(model.host == nil)
    }

    @Test("長條圖：期間決定根數(今天 1、7 天 7、30 天 30),最後一根是今天，沒用量的天補 0")
    func barsPerPeriod() {
        let meter = meter()
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 100)
        let model = model(meter)
        #expect(model.period == .month)
        #expect(model.bars.count == 30)
        model.period = .week
        #expect(model.bars.count == 7)
        #expect(model.bars.last?.day == "2026-11-21")
        #expect(model.bars.first?.day == "2026-11-15")
        #expect(model.bars.dropLast().allSatisfy { $0.total == 0 })
        #expect(model.bars.last?.total == 100)
        model.period = .today
        #expect(model.bars.map(\.day) == ["2026-11-21"])
    }

    @Test("分類：加總是一段;Wi-Fi 與行動網路分兩段(行動在下);送出與收到分兩段")
    func categories() {
        let meter = meter()
        let mac = Self.hostID(Self.mac)
        meter.record(hostID: mac, direction: .received, bytes: 800)
        meter.record(hostID: mac, direction: .sent, bytes: 200)
        meter.setNetwork(.cellular)
        meter.record(hostID: mac, direction: .received, bytes: 50)
        let model = model(meter)
        model.period = .today

        #expect(model.category == .total)
        #expect(model.bars[0].segments == [.init(kind: .total, bytes: 1_050)])

        model.category = .network
        #expect(model.bars[0].segments == [.init(kind: .cellular, bytes: 50), .init(kind: .wifi, bytes: 1_000)])

        model.category = .direction
        #expect(model.bars[0].segments == [.init(kind: .received, bytes: 850), .init(kind: .sent, bytes: 200)])
    }

    @Test("其他網路(有線、VPN)有量時才多一段，沒有就不出現")
    func otherNetworkSegmentOnlyWhenPresent() {
        let meter = meter()
        meter.setNetwork(.other)
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 10)
        let model = model(meter)
        model.period = .today
        model.category = .network
        #expect(model.bars[0].segments == [.init(kind: .other, bytes: 10)])
    }

    @Test("長條圖依主機過濾")
    func barsFollowHostFilter() {
        let meter = meter()
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 300)
        meter.record(hostID: Self.hostID(Self.linux), direction: .received, bytes: 70)
        let model = model(meter)
        model.period = .today
        model.selectHost(Self.linux)
        #expect(model.bars[0].total == 70)
    }

    @Test("點選一根長條取得那天;換期間、分類或主機後取消選取")
    func barSelection() {
        let meter = meter()
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 300)
        let model = model(meter)
        model.selectBar(day: "2026-11-21")
        #expect(model.selectedBar?.total == 300)
        model.selectBar(day: "2026-11-21")
        #expect(model.selectedBar == nil, "再點同一根取消")
        model.selectBar(day: "2026-11-21")
        model.category = .direction
        #expect(model.selectedBar == nil)
        model.selectBar(day: "2026-11-21")
        model.period = .week
        #expect(model.selectedBar == nil)
        model.selectBar(day: "2026-11-21")
        model.selectHost(Self.mac)
        #expect(model.selectedBar == nil)
        model.selectBar(day: "1999-01-01")
        #expect(model.selectedBar == nil, "不在長條圖裡的日子不選")
    }

    @Test("主機列表：依期間內用量由多到少;選了某台只列那台;沒用量的已存主機也列出")
    func hostRows() {
        let meter = meter()
        meter.record(hostID: Self.hostID(Self.linux), direction: .received, bytes: 900)
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 100)
        let model = model(meter)
        #expect(model.hostRows.map(\.name) == ["Linux", "Mac"])
        #expect(model.hostRows.map(\.bytes.total) == [900, 100])
        model.selectHost(Self.mac)
        #expect(model.hostRows.map(\.name) == ["Mac"])
    }

    @Test("已刪除主機的歷史仍算在所有主機裡，列表標示已刪除")
    func deletedHostStaysInAllHosts() {
        let meter = meter()
        meter.record(hostID: Self.deleted, direction: .received, bytes: 40)
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 10)
        let model = model(meter)
        #expect(model.today.total == 50)
        #expect(model.hostRows.first { $0.id == Self.deleted }?.isDeleted == true)
        #expect(model.hostRows.first { $0.id == Self.hostID(Self.mac) }?.isDeleted == false)
    }

    @Test("主機明細：期間內收到、送出、行動網路，以及 30 天合計")
    func hostDetail() {
        let meter = meter()
        let mac = Self.hostID(Self.mac)
        meter.record(hostID: mac, direction: .received, bytes: 700)
        meter.setNetwork(.cellular)
        meter.record(hostID: mac, direction: .sent, bytes: 60)
        clock.now = clock.now.addingTimeInterval(-10 * 86_400)
        meter.record(hostID: mac, direction: .received, bytes: 5_000)
        clock.now = clock.now.addingTimeInterval(10 * 86_400)
        let model = model(meter)
        model.period = .week
        let detail = model.detail(forHost: mac)
        #expect(detail?.received == 700)
        #expect(detail?.sent == 60)
        #expect(detail?.cellular == 60)
        #expect(detail?.thirtyDayTotal == 5_760)
    }

    @Test("重設統計:清掉所有歷史與這次開啟")
    func resetClearsEverything() {
        let meter = meter()
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 123)
        let model = model(meter)
        model.reset()
        #expect(model.today.total == 0)
        #expect(model.sinceLaunch.total == 0)
        #expect(model.bars.allSatisfy { $0.total == 0 })
        #expect(model.hostRows.allSatisfy { $0.bytes.total == 0 })
    }

    @Test("統計起算日:最早有資料的那天;沒有資料時是 nil")
    func countingSince() {
        let meter = meter()
        let model = model(meter)
        #expect(model.countingSince == nil)
        clock.now = clock.now.addingTimeInterval(-3 * 86_400)
        meter.record(hostID: Self.hostID(Self.mac), direction: .received, bytes: 1)
        clock.now = clock.now.addingTimeInterval(3 * 86_400)
        #expect(model.countingSince.map { calendar.dateComponents([.month, .day], from: $0) }?.day == 18)
    }

    @Test("畫面開著時每 2 秒重讀一次(等待由注入的 sleep 決定),取消後停止")
    func refreshesEveryTwoSecondsUntilCancelled() async {
        let sleeper = SteppingSleeper()
        let usage = DataUsageModel(
            meter: meter(), hosts: Self.options, currentHost: nil, now: { [clock] in clock.now }, calendar: calendar,
            sleep: sleeper.sleep)
        let task = Task { await usage.run() }

        await sleeper.advance()
        await UndoSendTests.until { usage.refreshCount == 1 }
        await sleeper.advance()
        await UndoSendTests.until { usage.refreshCount == 2 }
        #expect(await sleeper.requested.allSatisfy { $0 == .seconds(2) })
        #expect(usage.refreshCount == 2)

        // 第三次等待還在進行:取消後讓它結束,迴圈看到取消就停,不再重讀。
        task.cancel()
        await sleeper.advance()
        await task.value
        #expect(usage.refreshCount == 2)
    }
}

/// 流量圖 X 軸的標籤(#477):每天一個、不重複、略過時仍對齊長條。
@Suite("流量圖 X 軸標籤")
struct DataUsageAxisLabelsTests {
    @Test("兩天:每根長條一個標籤,不重複")
    func twoDays() {
        #expect(DataUsageAxisLabels.labeledIndices(barCount: 2, plotWidth: 300, labelWidth: 40) == [0, 1])
    }

    @Test("寬度夠:7 天每天都標")
    func sevenDaysFit() {
        #expect(DataUsageAxisLabels.labeledIndices(barCount: 7, plotWidth: 320, labelWidth: 40) == Array(0..<7))
    }

    @Test("30 天放不下:從今天往回每 N 天標一次,索引不重複、最後一根一定標")
    func thirtyDaysSkip() {
        let indices = DataUsageAxisLabels.labeledIndices(barCount: 30, plotWidth: 320, labelWidth: 40)
        #expect(indices.last == 29)
        #expect(Set(indices).count == indices.count)
        let gaps = Set(zip(indices, indices.dropFirst()).map { $1 - $0 })
        #expect(gaps.count == 1)
        // 相鄰標籤的間距(每根 320/30 pt)要容得下標籤寬度。
        #expect(Double(gaps.first ?? 0) * 320 / 30 >= 40)
    }

    @Test("沒有長條、寬度未知:不標或每根都標,不當掉")
    func degenerate() {
        #expect(DataUsageAxisLabels.labeledIndices(barCount: 0, plotWidth: 300, labelWidth: 40).isEmpty)
        #expect(DataUsageAxisLabels.labeledIndices(barCount: 3, plotWidth: 0, labelWidth: 40) == [0, 1, 2])
    }
}
#endif
