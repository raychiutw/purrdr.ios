/// 主機指令建構：讀對話紀錄的 POSIX 腳本(行為規格 §4.7)。
///
/// 每個腳本都以 `sh -c '<腳本>' sh <參數…>` 執行：登入 shell 可能是 zsh 或 fish,腳本本身一律交給 `sh`;
/// 資料(路徑、id、游標)以位置參數傳入，不拼進腳本。整段在 `LC_ALL=C` 下執行，`awk` 的 `length` 才是 byte 數
/// (R-S16)。腳本不寫明確的 `exit 0`(R-S12),不用可能空匹配的 glob(R-S11),不對管線用 `tail`(R-S17)。
///
/// 探測的 exit code:`3` 缺席(資料夾或檔案不在)、`4` 資料夾不可搜尋、`5` 檔案不可讀(R-I10)。
///
/// 每一行的輸出格式是「原始 byte 長度 TAB 剝除圖片後的行」,讓游標精確，同時 MB 級的圖片行只傳一點點(R-B06)。
/// 剝除：長度 ≥128 的 base64 字元引號字串、以及 `"data:…;base64,…"` 字串換成 `""`(R-B04)。
public enum TranscriptCommand {
    static let prefix = HerdrCommand.pathPrefix + " LC_ALL=C sh -c "

    /// 一行 `len TAB 行`,再剝除圖片。
    static let annotateAndStrip =
        ##"awk '{ print length($0) "\t" $0 }' | sed -e 's#"[A-Za-z0-9+/=]\{128,\}"#""#g' -e 's#"data:[^"]*;base64,[^"]*"#""#g'"##

    /// 檢查並印出大小。缺席、不可搜尋、不可讀各有 exit code。
    static let probe = #"""
    d=${f%/*}
    if [ ! -d "$d" ]; then exit 3; fi
    if [ ! -x "$d" ]; then exit 4; fi
    if [ ! -e "$f" ]; then exit 3; fi
    if [ ! -r "$f" ]; then exit 5; fi
    z=$(wc -c < "$f")
    z=$((z + 0))
    """#

    /// 定位：`<設定目錄>/projects/<資料夾>/<id>.jsonl`;不在時在所有專案資料夾找完全相同的檔名(worktree,#89)。
    /// 印出路徑與大小兩行。參數：session id、資料夾名。
    public static func locate(sessionID: String, projectFolder: String) -> String {
        let script = #"""
        c=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
        f="$c/projects/$2/$1.jsonl"
        if [ ! -e "$f" ] && [ -d "$c/projects" ]; then
        g=$(find "$c/projects" -mindepth 2 -maxdepth 2 -name "$1.jsonl" -print 2>/dev/null | head -n 1)
        if [ -n "$g" ]; then f=$g; fi
        fi
        printf '%s\n' "$f"
        """# + "\n" + probe + "\n" + #"printf '%s\n' "$z""#
        return command(script, arguments: [sessionID, projectFolder])
    }

    /// 視窗：以 `end` 為終點，往前取恰好 `lines` 行完整的行(行為規格 §4.7「開啟：讀最後 N 行」)。
    ///
    /// 從 `end` 往前取一塊(預設 4MB)數換行，不夠就把塊放大 4 倍再數，直到檔頭。視窗終點是塊內最後一個換行之後
    /// (正在寫的未完成行留給追蹤)。先印「起點 終點」,再印範圍內每一行。參數：路徑、終點、行數。
    public static func window(path: String, end: Int, lines: Int, chunkBytes: Int = 4 << 20) -> String {
        let script = #"""
        f=$1
        e=$2
        n=$3
        c=$4
        if [ ! -r "$f" ]; then exit 5; fi
        while :; do
        s=$((e - c))
        if [ "$s" -lt 0 ]; then s=0; fi
        if [ "$e" -gt "$s" ]; then
        r=$(tail -c +$((s + 1)) "$f" | head -c $((e - s)) | awk -v s="$s" -v t=$((e - s)) -v n="$n" '{ p = q + length($0) + 1; if (p <= t) { if (NR > 1 || s == 0) { k++; a[k] = q }; z = p }; q = p } END { if (k < n && s > 0) { print "more" } else { i = k - n + 1; if (i < 1) i = 1; b = (k > 0) ? a[i] : z; print (s + b) " " (s + z) } }')
        else
        r="$s $s"
        fi
        if [ "$r" != more ]; then break; fi
        c=$((c * 4))
        done
        printf '%s\n' "$r"
        a=${r% *}
        b=${r#* }
        if [ "$b" -gt "$a" ]; then
        tail -c +$((a + 1)) "$f" | head -c $((b - a)) | ANNOTATE
        fi
        """#.replacingOccurrences(of: "ANNOTATE", with: annotateAndStrip)
        return command(script, arguments: [path, String(end), String(lines), String(chunkBytes)])
    }

    /// 追蹤：印出目前大小;若比游標大且落差 ≤ `limit`,再印游標之後每一行**完整**的行。參數：路徑、游標、上限。
    public static func tail(path: String, from cursor: Int, limit: Int) -> String {
        let script = #"f=$1"# + "\n" + probe + "\n" + #"""
        printf '%s\n' "$z"
        if [ "$z" -gt "$2" ] && [ $((z - $2)) -le "$3" ]; then
        tail -c +$(($2 + 1)) "$f" | head -c $((z - $2)) | awk -v t=$((z - $2)) '{ p = q + length($0) + 1; if (p <= t) print; q = p }' | ANNOTATE
        fi
        """#.replacingOccurrences(of: "ANNOTATE", with: annotateAndStrip)
        return command(script, arguments: [path, String(cursor), String(limit)])
    }

    static func command(_ script: String, arguments: [String]) -> String {
        ([prefix + PosixShell.quote(script), "sh"] + arguments.map(PosixShell.quote)).joined(separator: " ")
    }
}
