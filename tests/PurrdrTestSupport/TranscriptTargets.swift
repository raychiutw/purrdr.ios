import PurrdrCore

/// 測試用的對話紀錄目標:以方言與參照組出,不必經過 Agent 與 herdr 的 session 參照。
extension TranscriptLocation {
    public static func id(_ locator: TranscriptLocator, _ id: String, cwd: String = "") -> TranscriptLocation {
        TranscriptLocation(locator: locator, reference: .id(id), cwd: cwd)
    }

    /// 回報路徑(Pi／OMP 路徑要檢查 header,agy 不用)。
    public static func path(_ path: String, readsHeader: Bool = false) -> TranscriptLocation {
        let dialect: TranscriptDialect = readsHeader ? .piJournal : .antigravity
        return TranscriptLocation(locator: dialect.reportedPathLocator ?? dialect.locator, reference: .path(path))
    }
}

extension TranscriptTarget {
    public static func id(_ dialect: TranscriptDialect, _ id: String, cwd: String = "") -> TranscriptTarget {
        TranscriptTarget(dialect: dialect, location: .id(dialect.locator, id, cwd: cwd), sessionKey: id)
    }

    public static func path(_ dialect: TranscriptDialect, _ path: String) -> TranscriptTarget {
        TranscriptTarget(dialect: dialect, location: .path(path, readsHeader: dialect == .piJournal), sessionKey: path)
    }
}
