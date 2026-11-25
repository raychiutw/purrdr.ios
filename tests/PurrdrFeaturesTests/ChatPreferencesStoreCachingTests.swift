import Foundation
import Testing
@testable import PurrdrAgentFeatures
import PurrdrCore

@MainActor
@Suite("聊天偏好存放處:解碼一次與 opened 修剪")
struct ChatPreferencesStoreCachingTests {
    @Test("存放處只解碼一次:反覆讀、改、存都不再解碼")
    func decodesOnlyOnce() throws {
        let defaults = UserDefaults(suiteName: "PrefsCache.\(UUID())")!
        let idA = UUID(), idB = UUID()
        let seed = [HostSelection.host(idA).storedValue: ChatPreferences(pinned: ["s1": Date()]),
                    HostSelection.host(idB).storedValue: ChatPreferences(muted: ["s2"])]
        defaults.set(try JSONEncoder().encode(seed), forKey: "chatPreferencesByHost")
        let all = UserDefaultsHostChatPreferencesStore(defaults: defaults)
        let a = all.store(for: .host(idA)), b = all.store(for: .host(idB))

        for _ in 0..<5 {
            var p = a.load()
            p.opened["x"] = Date()
            a.save(p)
            _ = b.load()
        }

        #expect(all.decodeCount == 1)
        #expect(a.load().pinned["s1"] != nil)
        #expect(b.load().muted == ["s2"])
        let relaunched = UserDefaultsHostChatPreferencesStore(defaults: defaults)
        #expect(relaunched.store(for: .host(idA)).load().opened["x"] != nil, "改動沒寫進 UserDefaults")
    }

    @Test("opened 修剪:早於保留天數且不在快照的移除,快照裡的與較新的保留")
    func prunesStaleOpened() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        var p = ChatPreferences(opened: [
            "old-gone": now.addingTimeInterval(-31 * day),
            "old-live": now.addingTimeInterval(-90 * day),
            "recent-gone": now.addingTimeInterval(-29 * day),
        ])
        p.pruneOpened(liveSessions: ["old-live"], now: now)
        #expect(Set(p.opened.keys) == ["old-live", "recent-gone"])
    }
}
