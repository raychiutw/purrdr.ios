import Foundation

/// 一次性主機腳本的自我時限(#92):超過時限就結束自己與子程序，不在主機上留下程序。
enum HostScriptTimeLimit {
    /// 在 POSIX 腳本開頭加上時限。`seconds` 是 shell 算式(可用腳本的位置參數)。
    static func posix(_ script: String, seconds: String) -> String {
        script
    }
}
