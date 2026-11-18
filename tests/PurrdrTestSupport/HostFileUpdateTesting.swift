import PurrdrCore

extension HostFileUpdate {
    /// 不帶已知版本的條件式讀取一定是 `.changed`:取出讀到的值;是 `.unchanged` 時丟錯。
    public func requireChanged() throws -> Value {
        guard case .changed(let value, _) = self else { throw UnexpectedlyUnchanged() }
        return value
    }
}

/// 不帶已知版本卻讀到 `.unchanged`。
public struct UnexpectedlyUnchanged: Error {}
