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
        ##"awk '{ print length($0) "\t" $0 }' | "## + stripImages

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
        command(claudeLocateScript, arguments: [sessionID, projectFolder])
    }

    package static let claudeLocateScript = #"""
        c=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
        f="$c/projects/$2/$1.jsonl"
        if [ ! -e "$f" ] && [ -d "$c/projects" ]; then
        g=$(find "$c/projects" -mindepth 2 -maxdepth 2 -name "$1.jsonl" -print 2>/dev/null | head -n 1)
        if [ -n "$g" ]; then f=$g; fi
        fi
        printf '%s\n' "$f"
        """# + "\n" + probe + "\n" + #"printf '%s\n' "$z""#

    // MARK: - 其他 agent 的定位(行為規格 §4.3–4.5)【未實測】

    /// 由 `$i`(session id 或回報的路徑)決定 `$f`。找不到是 exit 3(缺席)、資料夾不可搜尋 4、不只一個候選 6(有歧義)。
    /// 在列表預覽中於 subshell 執行，一個請求失敗不影響其他請求。
    static func resolver(for location: TranscriptTarget.Location) -> String {
        switch location {
        case .claude:
            // Claude 的定位腳本另有 worktree 後備(`locate(sessionID:projectFolder:)`);預覽只看預期路徑。
            #"f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$p/$i.jsonl""#
        case .grok:
            // cwd 的編碼由 Grok 決定、可能改變，所以找「深度剛好 2、名稱等於 id 的資料夾」。
            #"""
            h=${GROK_HOME:-$HOME/.grok}/sessions
            if [ ! -d "$h" ]; then exit 3; fi
            if [ ! -x "$h" ]; then exit 4; fi
            g=$(find "$h" -mindepth 2 -maxdepth 2 -type d -name "$i" -print 2>/dev/null)
            if [ -z "$g" ]; then exit 3; fi
            k=$(printf '%s\n' "$g" | wc -l)
            if [ $((k + 0)) -gt 1 ]; then exit 6; fi
            f="$g/updates.jsonl"
            """#
        case .antigravity:
            #"f="$HOME/.gemini/antigravity-cli/brain/$i/.system_generated/logs/transcript.jsonl""#
        case .piJournal:
            // Pi 預設 `~/.pi/agent`(`PI_CODING_AGENT_DIR`、`PI_CODING_AGENT_SESSION_DIR` 可改);OMP 是
            // `~/${PI_CONFIG_DIR:-.omp}/agent` 的 sessions 與 profiles,以及 `$XDG_DATA_HOME/omp`。精確檔名搜尋，不猜。
            #"""
            g=
            for d in "${PI_CODING_AGENT_SESSION_DIR:-}" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions" "$HOME/${PI_CONFIG_DIR:-.omp}/agent/sessions" "$HOME/${PI_CONFIG_DIR:-.omp}/agent/profiles" "${XDG_DATA_HOME:+$XDG_DATA_HOME/omp}"; do
            if [ -n "$d" ] && [ -d "$d" ]; then
            r=$(find "$d" -maxdepth 4 -type f \( -name "*_$i.jsonl" -o -name "$i.jsonl" \) -print 2>/dev/null)
            if [ -n "$r" ]; then g="$g$r
            "; fi
            fi
            done
            g=$(printf '%s' "$g" | sort -u)
            if [ -z "$g" ]; then exit 3; fi
            k=$(printf '%s\n' "$g" | wc -l)
            if [ $((k + 0)) -gt 1 ]; then exit 6; fi
            f=$g
            """#
        case .codex:
            // `${CODEX_HOME:-$HOME/.codex}` 的 sessions 與 archived_sessions 下，依日期分層。倒帶會留下
            // `rollout-<ts>-<id>_<rolloutId>.jsonl`:不只一個時問 Codex 自己的狀態資料庫(唯讀),等於候選之一的勝出;
            // 問不到 → 有歧義(6),不依新舊猜。只有 `.zst` → 已壓縮(7)。`$i` 已驗證只有安全字元，可放進 SQL。
            #"""
            h=${CODEX_HOME:-$HOME/.codex}
            g=
            z=
            for d in "$h/sessions" "$h/archived_sessions"; do
            if [ -d "$d" ]; then
            if [ ! -x "$d" ]; then exit 4; fi
            r=$(find "$d" -type f \( -name "rollout-*-$i.jsonl" -o -name "rollout-*-${i}_*.jsonl" \) -print 2>/dev/null)
            if [ -n "$r" ]; then g="$g$r
            "; fi
            r=$(find "$d" -type f \( -name "rollout-*-$i.jsonl.zst" -o -name "rollout-*-${i}_*.jsonl.zst" \) -print 2>/dev/null)
            if [ -n "$r" ]; then z=1; fi
            fi
            done
            g=$(printf '%s' "$g" | sort -u)
            if [ -z "$g" ]; then
            if [ -n "$z" ]; then exit 7; fi
            exit 3
            fi
            k=$(printf '%s\n' "$g" | wc -l)
            if [ $((k + 0)) -gt 1 ]; then
            w=$(find "$h" -maxdepth 1 -type f -name 'state_*.sqlite' -print 2>/dev/null | sort | while IFS= read -r s; do
            q=$(sqlite3 -readonly "$s" "select rollout_path from threads where id = '$i';" 2>/dev/null | head -n 1)
            if [ -n "$q" ] && printf '%s\n' "$g" | grep -F -x -q -e "$q"; then printf '%s\n' "$q"; break; fi
            done)
            if [ -z "$w" ]; then exit 6; fi
            g=$w
            fi
            f=$g
            """#
        case .reportedPath:
            "f=$i"
        }
    }

    /// 定位 Claude 以外的對話紀錄：印出路徑與大小兩行;`readsHeader` 時再印檔案前兩行(Pi／OMP、Codex 的 header 檢查)。
    /// 參數:session id 或回報的路徑。
    public static func locate(_ location: TranscriptTarget.Location, readsHeader: Bool) -> String {
        let value: String
        switch location {
        case .claude(let id, _), .grok(let id), .antigravity(let id), .piJournal(let id), .codex(let id): value = id
        case .reportedPath(let path): value = path
        }
        return command(locateScript(location, readsHeader: readsHeader), arguments: [value])
    }

    package static func locateScript(_ location: TranscriptTarget.Location, readsHeader: Bool) -> String {
        var script = "i=$1\n" + resolver(for: location) + "\n" + probe + "\n" + #"printf '%s\n%s\n' "$f" "$z""#
        if readsHeader { script += "\n" + #"head -n 2 "$f""# }
        return script
    }

    /// 視窗：以 `end` 為終點，往前取恰好 `lines` 行完整的行(行為規格 §4.7「開啟：讀最後 N 行」)。
    ///
    /// 從 `end` 往前取一塊(預設 4MB)數換行，不夠就把塊放大 4 倍再數，直到檔頭。視窗終點是塊內最後一個換行之後
    /// (正在寫的未完成行留給追蹤)。先印「起點 終點」,再印範圍內每一行。參數：路徑、終點、行數。
    public static func window(path: String, end: Int, lines: Int, chunkBytes: Int = 4 << 20) -> String {
        command(windowScript, arguments: [path, String(end), String(lines), String(chunkBytes)])
    }

    package static let windowScript = #"""
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

    /// 追蹤：印出目前大小;若比游標大且落差 ≤ `limit`,再印游標之後每一行**完整**的行。參數：路徑、游標、上限。
    public static func tail(path: String, from cursor: Int, limit: Int) -> String {
        command(tailScript, arguments: [path, String(cursor), String(limit)])
    }

    package static let tailScript = #"f=$1"# + "\n" + probe + "\n" + #"""
        printf '%s\n' "$z"
        if [ "$z" -gt "$2" ] && [ $((z - $2)) -le "$3" ]; then
        tail -c +$(($2 + 1)) "$f" | head -c $((z - $2)) | awk -v t=$((z - $2)) '{ p = q + length($0) + 1; if (p <= t) print; q = p }' | ANNOTATE
        fi
        """#.replacingOccurrences(of: "ANNOTATE", with: annotateAndStrip)

    /// 分段追趕(#130):印出目前大小;比游標大時，再印游標之後的完整行，累計原始 byte 數不超過 `limit`
    /// (即使後面還有，留給下一次從新游標接著讀)。第一行就超過 `limit` 時只印那一行，剝除圖片後的內容截短到
    /// `limit` bytes(原始長度照實印，游標照樣前進;傳輸量不超過上限，期限也依上限估算)。參數：路徑、游標、上限。
    public static func catchUp(path: String, from cursor: Int, limit: Int) -> String {
        command(catchUpScript, arguments: [path, String(cursor), String(limit)])
    }

    package static let catchUpScript = #"f=$1"# + "\n" + probe + "\n" + #"""
        printf '%s\n' "$z"
        if [ "$z" -gt "$2" ]; then
        tail -c +$(($2 + 1)) "$f" | head -c $((z - $2)) | awk -v t=$((z - $2)) -v m="$3" '{ p = q + length($0) + 1; if (p > t || (p > m && NR > 1)) exit; print; q = p }' | ANNOTATE | awk -v m="$3" '{ i = index($0, "\t"); if (length($0) - i > m) $0 = substr($0, 1, i + m); print }'
        fi
        """#.replacingOccurrences(of: "ANNOTATE", with: annotateAndStrip)

    /// 長駐追蹤腳本(#166):一條 exec 通道服務所有追蹤中的路徑，閒置 `idleSeconds` 或總長 `totalSeconds` 到了以 exit 124 結束。
    package static func follow(
        limit: Int = TranscriptReader.catchUpLimit, backlogLimit: Int = TranscriptReader.catchUpBacklogLimit,
        idleSeconds: Int = HostScriptTimeLimit.followIdleSeconds, totalSeconds: Int = HostScriptTimeLimit.followTotalSeconds
    ) -> String {
        "purrdr-follow"
    }

    /// Claude Code 聊天的列表預覽(參數：每個請求的 key、session id、資料夾名)。見 `previews(marker:entries:)`。
    public static func previews(marker: String, requests: [(key: String, sessionID: String, projectFolder: String)]) -> String {
        previews(marker: marker, entries: requests.map { PreviewEntry(key: $0.key, type: "claude", value: $0.sessionID, extra: $0.projectFolder) })
    }

    /// 列表預覽的一個請求：key、定位方式、id 或路徑、Claude 的資料夾名。
    package struct PreviewEntry: Sendable, Equatable {
        package var key: String
        package var type: String
        package var value: String
        package var extra: String

        package init(key: String, type: String, value: String, extra: String = "") {
            self.key = key
            self.type = type
            self.value = value
            self.extra = extra
        }

        /// id 或路徑不安全時為 `nil`(不進 shell,R-I12)。
        package init?(_ request: PreviewRequest) {
            let header = request.target.format == .piJournal
            switch request.target.location {
            case .claude(let id, let cwd):
                guard ClaudeTranscript.isSafeSessionID(id) else { return nil }
                self.init(key: request.key, type: "claude", value: id, extra: ClaudeTranscript.projectFolder(forCWD: cwd))
            case .grok(let id), .antigravity(let id), .piJournal(let id), .codex(let id):
                guard ClaudeTranscript.isSafeSessionID(id) else { return nil }
                let type = switch request.target.location {
                case .grok: "grok"
                case .antigravity: "agy"
                case .codex: "codex"
                default: "pi"
                }
                self.init(key: request.key, type: type, value: id)
            case .reportedPath(let path):
                guard TranscriptReader.isValidPath(path) else { return nil }
                self.init(key: request.key, type: header ? "pipath" : "path", value: path)
            }
        }
    }

    /// 列表預覽：每個請求印一行「分隔標記 key」,再印剝除圖片後的檔尾 48,000 bytes(§4.7);Pi／OMP 先印
    /// 「分隔標記! key」與檔案前兩行(header 檢查)。每個請求在 subshell 裡定位，一個檔不存在或有歧義不讓整批失敗。
    /// 參數：標記，接著每個請求四個(key、定位方式、id 或路徑、Claude 的資料夾名)。
    package static func previews(marker: String, entries: [PreviewEntry]) -> String {
        command(previewsScript, arguments: [marker] + entries.flatMap { [$0.key, $0.type, $0.value, $0.extra] })
    }

    /// 列表預覽每個請求最多讀的檔尾 bytes(與 `previewsScript` 的 `tail -c` 相同;估算期限用)。
    package static let previewBytes = 48_000

    package static let previewsScript = #"""
        m=$1
        shift
        while [ $# -ge 4 ]; do
        printf '%s %s\n' "$m" "$1"
        (
        y=$1
        t=$2
        i=$3
        p=$4
        case $t in
        claude)
        @CLAUDE@
        ;;
        grok)
        @GROK@
        ;;
        agy)
        @AGY@
        ;;
        pi)
        @PI@
        ;;
        codex)
        @CODEX@
        ;;
        *)
        f=$i
        ;;
        esac
        if [ -r "$f" ]; then
        case $t in
        pi|pipath|codex)
        printf '%s! %s\n' "$m" "$y"
        head -n 2 "$f" | @STRIP@
        printf '\n%s %s\n' "$m" "$y"
        ;;
        esac
        tail -c 48000 "$f" | @STRIP@
        printf '\n'
        fi
        )
        shift 4
        done
        """#
            .replacingOccurrences(of: "@CLAUDE@", with: resolver(for: .claude(sessionID: "", cwd: "")))
            .replacingOccurrences(of: "@GROK@", with: resolver(for: .grok(sessionID: "")))
            .replacingOccurrences(of: "@AGY@", with: resolver(for: .antigravity(sessionID: "")))
            .replacingOccurrences(of: "@PI@", with: resolver(for: .piJournal(sessionID: "")))
            .replacingOccurrences(of: "@CODEX@", with: resolver(for: .codex(sessionID: "")))
            .replacingOccurrences(of: "@STRIP@", with: stripImages)

    /// 找 subagent:在 `<session>/subagents/` 用 `find`(不用 glob,R-S11)列出 `agent-*.meta.json`,
    /// 內容含呼叫 id 的每個 meta 印兩行「路徑」與「內容(去掉換行)」。是否**完全相等**由 client 解析 JSON 後確認(R-W02)。
    /// 沒有資料夾 → exit 3。參數:session 資料夾、呼叫 id。
    public static func findSubagent(sessionFolder: String, callID: String) -> String {
        command(findSubagentScript, arguments: [sessionFolder, callID])
    }

    package static let findSubagentScript = #"""
        d=$1/subagents
        if [ ! -d "$d" ]; then exit 3; fi
        if [ ! -x "$d" ]; then exit 4; fi
        find "$d" -maxdepth 1 -type f -name 'agent-*.meta.json' -print | while IFS= read -r m; do
        if grep -q -F -e "$2" "$m"; then
        printf '%s\n' "$m"
        tr -d '\n' < "$m"
        printf '\n'
        fi
        done
        """#

    /// 讀 workflow 進度:`<session>/workflows/<runId>.json`(結束時才寫)優先，否則
    /// `<session>/subagents/workflows/<runId>/journal.jsonl`。先印「種類 checksum」一行;與參數 3 相同就不印內容(R-W03)。
    /// 兩個都沒有 → exit 3。參數:session 資料夾、run id、上次的「種類 checksum」(沒有給空字串)。
    public static func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String) -> String {
        command(readWorkflowScript, arguments: [sessionFolder, runID, knownChecksum])
    }

    package static let readWorkflowScript = #"""
        r=$1/workflows/$2.json
        j=$1/subagents/workflows/$2/journal.jsonl
        if [ -f "$r" ]; then k=run; f=$r; elif [ -f "$j" ]; then k=journal; f=$j; else exit 3; fi
        if [ ! -r "$f" ]; then exit 5; fi
        c=$(cksum < "$f")
        printf '%s %s\n' "$k" "$c"
        if [ "$k $c" != "$3" ]; then cat "$f"; fi
        """#

    /// 委派是否結束(§4.6、R-W04):在父對話紀錄中找含呼叫 id 或 agent id 的行。先印這些行(剝圖後)的 checksum;
    /// 與參數 4 相同就不印內容，否則每行印「原始 byte 長度 TAB 剝除圖片後的行」。參數：路徑、id、id、上次 checksum。
    public static func delegationLines(path: String, ids: (String, String), knownChecksum: String) -> String {
        command(delegationLinesScript, arguments: [path, ids.0, ids.1, knownChecksum])
    }

    package static let delegationLinesScript = #"""
        f=$1
        if [ ! -r "$f" ]; then exit 5; fi
        c=$(grep -F -e "$2" -e "$3" "$f" | STRIP | cksum)
        printf '%s\n' "$c"
        if [ "$c" != "$4" ]; then
        grep -F -e "$2" -e "$3" "$f" | ANNOTATE
        fi
        """#.replacingOccurrences(of: "ANNOTATE", with: annotateAndStrip).replacingOccurrences(of: "STRIP", with: stripImages)

    static let stripImages = ##"sed -e 's#"[A-Za-z0-9+/=]\{128,\}"#""#g' -e 's#"data:[^"]*;base64,[^"]*"#""#g'"##

    package static func command(_ script: String, arguments: [String]) -> String {
        ([prefix + PosixShell.quote(HostScriptTimeLimit.posixRead(script)), "sh"] + arguments.map(PosixShell.quote)).joined(separator: " ")
    }
}
