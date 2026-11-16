import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 訂閱的事件型別只能是 herdr 認得的：任何一個未知型別會讓 herdr 拒絕整個訂閱(行為規格 §3.7)。
@Suite("事件訂閱")
struct EventSubscriptionTests {
    @Test("全主機訂閱的每個型別都在真實 herdr 回報的可訂閱清單裡")
    func hostWideTypesAreKnownToHerdr() throws {
        // 錄製：送一個 herdr 不認得的型別時，錯誤訊息列出所有可訂閱的型別(`expected one of …`)。
        let message = String(decoding: Fixtures.data("error.unknown-subscription-type.ndjson"), as: UTF8.self)
        let list = try #require(message.range(of: "expected one of ").map { message[$0.upperBound...] })
        let known = Set(list.matches(of: /`([a-z_.]+)`/).map { String($0.output.1) })
        #expect(known.count > 20, "沒有解析到清單")

        for subscription in EventSubscription.hostWide {
            #expect(known.contains(subscription.type.rawValue), "\(subscription.type.rawValue)")
        }
        #expect(EventSubscription.hostWide.map(\.type).contains(.layoutUpdated), "Spaces 檢視要訂閱版面事件(#40)")
    }
}
