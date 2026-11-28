import Foundation
import PurrdrCore
import PurrdrNotificationContent
import Testing

@Suite("推播補上主機名稱")
struct PushHostNamesTests {
    let names = ["hash-studio": "Studio Mac", "hash-build": "Build Box"]

    @Test("有對應:副標題換成主機名稱,標題不動")
    func hasMapping() {
        let content = PushNotificationEnrichment.enriched(
            title: "ledger · Claude Code", subtitle: "", userInfo: ["pairing": "hash-studio", "pane": "w1:p1"], hostNames: names)
        #expect(content == .init(title: "ledger · Claude Code", subtitle: "Studio Mac"))
    }

    @Test("沒有對應:原樣送出")
    func noMapping() {
        let content = PushNotificationEnrichment.enriched(
            title: "ledger", subtitle: "", userInfo: ["pairing": "hash-unknown"], hostNames: names)
        #expect(content == .init(title: "ledger", subtitle: ""))
    }

    @Test("舊 payload 沒有 Tab:標題只有 workspace,副標題照樣補")
    func oldPayloadWithoutTab() {
        let content = PushNotificationEnrichment.enriched(
            title: "ledger", subtitle: "", userInfo: ["pairing": "hash-build"], hostNames: names)
        #expect(content == .init(title: "ledger", subtitle: "Build Box"))
    }

    @Test("每日上限通知(根層 pairing 與 event,沒有 pane):照常補上主機名稱;對應不到就原樣")
    func dailyLimitWithoutPane() {
        let info: [AnyHashable: Any] = ["pairing": "hash-studio", "event": "daily_limit_reached"]
        #expect(PushNotificationEnrichment.enriched(title: "Daily notification limit reached", subtitle: "", userInfo: info, hostNames: names)
            == .init(title: "Daily notification limit reached", subtitle: "Studio Mac"))
        #expect(PushNotificationEnrichment.enriched(title: "Daily notification limit reached", subtitle: "", userInfo: info, hostNames: [:])
            == .init(title: "Daily notification limit reached", subtitle: ""))
    }

    @Test("新通知種類(#707,沒有 pane 的狀態通知):有對應就補主機名稱,沒有就原樣送出,標題不動",
          arguments: [
              ("host_offline", "Host offline"), ("host_recovered", "Host back online"), ("usage_alert", "Plan usage"),
          ])
    func newKindsWithoutPane(event: String, title: String) {
        let info: [AnyHashable: Any] = ["pairing": "hash-build", "event": event]
        #expect(PushNotificationEnrichment.enriched(title: title, subtitle: "", userInfo: info, hostNames: names)
            == .init(title: title, subtitle: "Build Box"))
        #expect(PushNotificationEnrichment.enriched(title: title, subtitle: "", userInfo: info, hostNames: [:])
            == .init(title: title, subtitle: ""))
    }

    @Test("長時間工作完成與預約送出被暫停(帶 pane,queue_paused 另有根層 status):補主機名稱")
    func paneStatusNotifications() {
        let longWork: [AnyHashable: Any] = ["pairing": "hash-studio", "pane": "w1:p1"]
        let paused: [AnyHashable: Any] = ["pairing": "hash-studio", "pane": "w1:p1", "status": "queue_paused"]
        for info in [longWork, paused] {
            #expect(PushNotificationEnrichment.enriched(title: "ledger · Tab", subtitle: "", userInfo: info, hostNames: names)
                == .init(title: "ledger · Tab", subtitle: "Studio Mac"))
        }
    }

    @Test("沒有 pairing 或對應表是空的:原樣送出,不丟錯")
    func missingPairingOrEmptyMap() {
        #expect(
            PushNotificationEnrichment.enriched(title: "t", subtitle: "", userInfo: [:], hostNames: names)
                == .init(title: "t", subtitle: ""))
        #expect(
            PushNotificationEnrichment.enriched(title: "t", subtitle: "", userInfo: ["pairing": "hash-studio"], hostNames: [:])
                == .init(title: "t", subtitle: ""))
    }

    @Test("對應表的名稱是空白時不補")
    func blankName() {
        let content = PushNotificationEnrichment.enriched(
            title: "t", subtitle: "", userInfo: ["pairing": "h"], hostNames: ["h": "   "])
        #expect(content.subtitle == "")
    }

    @Test("後台已帶副標題(電腦名稱,#706):用後台的,不被本機對應表蓋掉,也不重複補")
    func backendSubtitleWins() {
        let info: [AnyHashable: Any] = ["pairing": "hash-studio", "pane": "w1:p1"]
        // 後台名稱與本機不同(例如剛在別台改名):以後台為準。
        #expect(PushNotificationEnrichment.enriched(title: "ledger", subtitle: "Studio (renamed)", userInfo: info, hostNames: names)
            == .init(title: "ledger", subtitle: "Studio (renamed)"))
        // 後台沒帶(空字串或只有空白):由本機對應表補上。
        #expect(PushNotificationEnrichment.enriched(title: "ledger", subtitle: "  ", userInfo: info, hostNames: names)
            == .init(title: "ledger", subtitle: "Studio Mac"))
        // 兩邊都沒有:原樣。
        #expect(PushNotificationEnrichment.enriched(title: "ledger", subtitle: "", userInfo: info, hostNames: [:])
            == .init(title: "ledger", subtitle: ""))
    }

    @Test("對應表由配對與主機名稱組出,沒有名稱的配對略過")
    func mapBuilding() {
        let map = PushHostNameMap.make(
            pairings: ["a": "hash-a", "b": "hash-b", "gone": "hash-gone"], hostNames: ["a": "Studio Mac", "b": "Build Box"])
        #expect(map == ["hash-a": "Studio Mac", "hash-b": "Build Box"])
    }

    @Test("儲存來回:存什麼讀什麼,沒存過是空的")
    func userDefaultsRoundTrip() {
        let suite = "purrdr.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = UserDefaultsPushHostNames(suiteName: suite)
        #expect(store.load() == [:])
        store.save(["h": "Studio Mac"])
        #expect(UserDefaultsPushHostNames(suiteName: suite).load() == ["h": "Studio Mac"])
        store.save([:])
        #expect(store.load() == [:])
    }
}
