import Foundation

/// 一次性主機腳本的自我時限(#92):超過時限就結束自己與子程序，不在主機上留下程序。
///
/// 長時間的串流(`events.subscribe` 的 bridge、`terminal session control`)不加：它們靠 stdin EOF 結束。
enum HostScriptTimeLimit {
    /// 唯讀腳本的整體時限(秒)。比 app 端最長的讀取期限寬，app 先逾時，主機只負責收尾。
    static let readSeconds = 120
    /// Windows stdin stub 等完整腳本(結束標記)的時限(秒)。
    static let stdinScriptSeconds = 30
    /// 上傳的時限：`readSeconds` 加上以這個速度(bytes/秒)估算的傳輸時間(app 端以 32 KiB/s 估算)。
    static let uploadBytesPerSecond = 16_000
    /// 逾時的 exit code(同 GNU `timeout`)。
    static let exitCode = 124
    /// 帶時限的 POSIX 腳本都有這個函式名稱(守門測試用)。
    static let posixMarker = "purrdr_limit"

    /// 唯讀腳本：固定 `readSeconds`。
    static func posixRead(_ script: String) -> String {
        posix(script, seconds: String(readSeconds))
    }

    /// 上傳腳本：時限隨傳輸大小加長。`transferSizeParameter` 是傳輸大小在第幾個位置參數。
    static func posixUpload(_ script: String, transferSizeParameter: Int) -> String {
        posix(script, seconds: "$((\(readSeconds) + $\(transferSizeParameter) / \(uploadBytesPerSecond)))")
    }

    /// 在 POSIX 腳本開頭加上時限。`seconds` 是 shell 算式(可用腳本的位置參數)。
    ///
    /// macOS 沒有 `timeout`:背景的 shell 每秒確認腳本還在，到時限就停住腳本的整棵程序樹(`ps` 的 pid／ppid)、
    /// 送 TERM(腳本以 124 結束，自己的 trap 照常清暫存檔),1 秒後 KILL 剩下的。不依賴程序群組：
    /// sshd 以外(Tailscale SSH、測試)啟動時，腳本不一定是群組的 leader。背景 shell 的 stdio 接 `/dev/null`,不佔住 channel。
    /// 結尾的 `exit $?` 讓 bash 不把最後一個指令 exec 掉(否則 trap 跟著消失，逾時變成被 TERM 結束)。
    static func posix(_ script: String, seconds: String) -> String {
        """
        purrdr_tree() {
        ps -A -o pid= -o ppid= 2>/dev/null | awk -v r="$1" -v s="$2" '{ c[$2] = c[$2] " " $1 } END { q = r; while (q != "") { n = split(q, a, " "); q = ""; for (i = 1; i <= n; i++) if (a[i] != s) { printf "%s ", a[i]; q = q " " c[a[i]] } } }'
        }
        purrdr_limit() {
        n=0
        while [ "$n" -lt "$2" ]; do kill -0 "$1" 2>/dev/null || exit 0; sleep 1; n=$((n + 1)); done
        s=$(exec sh -c 'echo "$PPID"')
        t=$(purrdr_tree "$1" "$s")
        if [ -z "$t" ]; then t=$1; fi
        kill -STOP $t 2>/dev/null
        t="$t $(purrdr_tree "$1" "$s")"
        kill -TERM $t 2>/dev/null
        kill -CONT $t 2>/dev/null
        sleep 1
        kill -KILL $t 2>/dev/null
        }
        trap 'exit \(exitCode)' TERM
        purrdr_limit "$$" "\(seconds)" < /dev/null > /dev/null 2>&1 &
        \(script)
        exit $?
        """
    }
}
