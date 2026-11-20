/// 推播配對要收的推播種類(raychiutw/purrdr.server#10 的 `kinds`);原始值就是 wire 上的值。
///
/// 主機外掛照樣送每個狀態，由後台依配對的種類決定是否轉 APNs,所以主機端不需要知道。
public enum PushKind: String, Sendable, CaseIterable, Hashable {
    /// 「需要你」:Agent 進入 `blocked`。
    case blocked
    /// 「完成」:Agent 進入 `done`。
    case done

    /// wire 上的陣列：依 `allCases` 的順序，讓同一組種類每次送出都一樣。
    public static func wireValues(_ kinds: Set<PushKind>) -> [String] {
        allCases.filter(kinds.contains).map(\.rawValue)
    }
}
