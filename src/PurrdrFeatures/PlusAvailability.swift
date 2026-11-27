import Foundation
import PurrdrAgentFeatures
import PurrdrCore

/// 這個 build 有沒有提供 Purrdr Plus(訂閱與需要訂閱的主機同步,#676、spec #674)。
///
/// 值來自 build setting `PURRDR_PLUS_ENABLED`(Release 關閉、Debug 開啟),經 app 的 Info.plist
/// 鍵 `PurrdrPlusEnabled` 帶進來,只在 app 入口讀一次、轉成這個型別。
/// 不用 `AppTransaction` 判斷安裝來源、也沒有遠端開關(App Review Guidelines 2.3.1)。
///
/// 關閉時 `assemble` 不建立訂閱與主機同步的 model(畫面沿用「兩者可以是 nil」的慣例):
/// 付費牆、Plus 卡、訂閱提示、主機同步都不出現,StoreKit 交易監聽與主機同步也不啟動。
/// 會員、通知、設定照常。
public enum PlusAvailability: Equatable, Sendable {
    case enabled
    case disabled

    /// Info.plist 的 `PurrdrPlusEnabled`。只有明確的 YES(字串或布林)才開啟;沒寫、NO、
    /// 沒被取代的 `$(PURRDR_PLUS_ENABLED)` 與其他值一律關閉,預設是安全的一邊。
    public init(infoValue: Any?) {
        switch infoValue {
        case let value as String where value.lowercased() == "yes" || value.lowercased() == "true":
            self = .enabled
        case let value as Bool where value:
            self = .enabled
        default:
            self = .disabled
        }
    }

    /// 組裝訂閱與主機同步。關閉時兩個都是 `nil`。
    @MainActor
    public func assemble(
        session: MemberSession, store: any PlusStore, confirmOwner: @escaping @MainActor @Sendable () async -> Bool,
        hosts: HostsModel, hostSyncStore: any HostSyncStore
    ) -> PlusModels {
        guard self == .enabled else { return PlusModels(plus: nil, hostSync: nil) }
        let plus = SubscriptionModel(session: session, store: store, confirmOwner: confirmOwner)
        let hostSync = HostSyncModel(session: session, plus: plus, hosts: hosts, store: hostSyncStore)
        return PlusModels(plus: plus, hostSync: hostSync)
    }
}

/// `PlusAvailability.assemble` 的結果。
public struct PlusModels {
    public let plus: SubscriptionModel?
    public let hostSync: HostSyncModel?
}
