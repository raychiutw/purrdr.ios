/// herdr 回報的 agent 種類字串 → 正式名稱(herdr `src/detect/mod.rs`)。
///
/// 轉換本身在 `AgentID`(#438);這裡保留舊寫法給尚未搬到設定檔的分流判斷。新程式請用 `AgentID`／`AgentCatalog`。
public enum AgentKindName {
    public static func canonical(_ kind: String) -> String {
        AgentID(herdrName: kind).canonicalName
    }
}
