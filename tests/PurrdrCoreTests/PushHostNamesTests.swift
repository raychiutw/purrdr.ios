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
