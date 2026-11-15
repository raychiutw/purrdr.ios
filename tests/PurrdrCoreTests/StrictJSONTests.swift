import Foundation
@testable import PurrdrCore
import Testing

/// 設定檔要連 Claude Code(`JSON.parse`)都讀得了，我們才修改它。
@Suite("嚴格 JSON")
struct StrictJSONTests {
    @Test("合法的 JSON", arguments: [
        #"{}"#, #"[]"#, #" {"a": [1, -2.5e+3, true, false, null, "x\"é\n"]} "#, #"0"#, #""s""#,
        "{\n  \"statusLine\": {\"type\": \"command\"}\n}\n",
    ])
    func acceptsValidJSON(_ text: String) {
        #expect(StrictJSON.isValid(Data(text.utf8)))
    }

    @Test("寬鬆語法一律不接受", arguments: [
        #"{"a":1,}"#, #"[1,2,]"#, #"{a:1}"#, #"{'a':1}"#, #"// c"# + "\n{}", #"01"#, #"1."#, #"-"#, "",
        #"{"a":1} x"#, #"{"a":"\q"}"#, "\"tab\there\"", #"NaN"#, #"{"a" 1}"#,
    ])
    func rejectsLenientJSON(_ text: String) {
        #expect(!StrictJSON.isValid(Data(text.utf8)))
    }
}
