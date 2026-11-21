/// 推播配對要收的推播種類(raychiutw/purrdr.server#10 的 `kinds`);原始值就是 wire 上的值。
///
/// 主機外掛照樣送每個狀態，由後台依配對的種類決定是否轉 APNs,所以主機端不需要知道。
public enum PushKind: String, Sendable, CaseIterable, Hashable {
    /// 「需要你」:Agent 進入 `blocked`。
    case blocked
    /// 「完成」:Agent 進入 `done`。
    case done
    /// 「可能卡住」:主機服務的 Agent 觀察者看到 working 的 Agent 畫面 10 分鐘沒變(raychiutw/purrdr.server#15、purrdr.host#31)。
    case stuck
    /// 「仍在等你」:Agent 停在 `blocked` 15 分鐘(錯過「需要你」後再提醒一次)。
    case reminder
    /// 「主機服務」:主機服務的更新事件(有新版、已更新、已退回;raychiutw/purrdr.server#11)。
    case hostService = "host_service"

    /// 要較新主機服務才會送的種類：只有主機服務的 Agent 觀察者偵測得到(#311)。
    public var requiredHostServiceFeature: HostServiceFeature? {
        switch self {
        case .stuck, .reminder: .agentObserver
        case .blocked, .done, .hostService: nil
        }
    }

    /// 回報 `installedVersion` 的主機服務太舊、送不出這個種類;版本未知(還沒連上)時不擋。
    public func needsHostServiceUpdate(installedVersion: String?) -> Bool {
        needsHostServiceUpdate(installed: installedVersion.flatMap(HostServiceVersion.init))
    }

    /// 同上,已解析成 `HostServiceVersion` 的版本。
    public func needsHostServiceUpdate(installed: HostServiceVersion?) -> Bool {
        guard let feature = requiredHostServiceFeature, let installed else { return false }
        return installed < feature.minimumVersion
    }

    /// wire 上的陣列：依 `allCases` 的順序，讓同一組種類每次送出都一樣。
    public static func wireValues(_ kinds: Set<PushKind>) -> [String] {
        allCases.filter(kinds.contains).map(\.rawValue)
    }
}
