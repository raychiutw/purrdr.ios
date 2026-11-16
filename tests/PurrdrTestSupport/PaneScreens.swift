import Foundation

/// Blocked 提示的終端機畫面(`Fixtures/screens/*.txt`)與 `pane.read` 回應。
///
/// 畫面**不是錄製的**:作者主機上沒有正在問問題的 agent,而為了錄製去製造 blocked 狀態會把按鍵送進真的 agent。
/// 這些畫面依行為規格 §5.2–§5.4 描述的形狀手寫(內容自己寫);`pane.read` 的 envelope 取自唯讀錄製的
/// `pane.read.visible.ndjson`,只換掉 `text`(見 `Fixtures/README.md`)。
public enum PaneScreens {
    /// 一份手寫畫面的文字。
    public static func text(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/screens"),
              let data = try? Data(contentsOf: url) else {
            fatalError("找不到畫面 Fixtures/screens/\(name).txt")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `pane.read` 回應：錄製的 envelope,畫面換成 `name`。
    public static func read(_ name: String) -> FakeReply {
        read(text: text(name))
    }

    /// `pane.read` 回應：錄製的 envelope,畫面換成 `text`。
    public static func read(text: String) -> FakeReply {
        .recorded("pane.read.visible.ndjson") { response in
            guard var result = response["result"] as? [String: Any], var read = result["read"] as? [String: Any] else { return }
            read["text"] = text
            result["read"] = read
            response["result"] = result
        }
    }
}
