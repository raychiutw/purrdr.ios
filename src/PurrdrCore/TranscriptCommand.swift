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

    // MARK: - 通用的定位(行為規格 §4.1–4.5)

    /// 定位對話紀錄(任一種位置規則):印出路徑與大小兩行;位置規則要檢查 header 時再印檔案前兩行(Pi／OMP、Codex)。
    /// 參數:session id 或回報的路徑(Claude 另帶 cwd 轉成的資料夾名)。
    public static func locate(_ location: TranscriptLocation) -> String {
        var arguments = [location.reference.value]
        if location.locator.usesProjectFolder { arguments.append(ClaudeTranscript.projectFolder(forCWD: location.cwd)) }
        return command(locateScript(location.locator), arguments: arguments)
    }

    package static func locateScript(_ locator: TranscriptLocator) -> String {
        if let custom = locator.customLocateScript { return custom }
        var script = "i=$1\n" + locator.resolver + "\n" + probe + "\n" + #"printf '%s\n%s\n' "$f" "$z""#
        if locator.readsHeader { script += "\n" + #"head -n 2 "$f""# }
        return script
    }

    /// 開啟聊天(#656):定位加視窗合成一個指令,手機只等一次往返。輸出:定位的輸出(路徑、大小、要檢查 header 時再接檔案前兩行),
    /// 一行 `openMarker`,再接與 `window` 相同的輸出(「起點 終點」與每行)。視窗終點是定位時量到的大小。
    /// `maxBytes` 大於 0 時範圍只取終點往前那麼多 bytes 內完整的行(不放大區塊),否則照 `window` 的預設區塊。
    /// 可讀訊息與否仍由 app 的解析器判斷,這裡不放第二套規則。參數:session id 或路徑、Claude 的資料夾名(沒有給空字串)、行數、maxBytes。
    public static func open(_ location: TranscriptLocation, lines: Int, maxBytes: Int) -> String {
        let folder = location.locator.usesProjectFolder ? ClaudeTranscript.projectFolder(forCWD: location.cwd) : ""
        return command(openScript(location.locator), arguments: [location.reference.value, folder, String(lines), String(maxBytes)])
    }

    /// 定位輸出與視窗輸出之間的分隔行。
    public static let openMarker = "purrdr-window"

    package static func openScript(_ locator: TranscriptLocator) -> String {
        locateScript(locator) + "\n" + "printf '%s\\n' \(openMarker)\n" + #"""
            e=$z
            n=$3
            c=$4
            g=1
            if [ "$c" -le 0 ]; then c=4194304; g=0; fi
            """# + "\n" + windowBody
    }

    /// 視窗：以 `end` 為終點，往前取恰好 `lines` 行完整的行(行為規格 §4.7「開啟：讀最後 N 行」)。
    ///
    /// 從 `end` 往前取一塊(預設 4MB)數換行，不夠就把塊放大 4 倍再數，直到檔頭。視窗終點是塊內最後一個換行之後
    /// (正在寫的未完成行留給追蹤)。先印「起點 終點」,再印範圍內每一行。參數：路徑、終點、行數。
    ///
    /// `maxBytes` 大於 0(#356,第五個參數)時：只取終點往前 `maxBytes` bytes 內完整的行，不放大區塊，所以傳輸量有上限;
    /// 範圍內不夠 `lines` 行就回有多少給多少(一行都放不下時範圍是空的)。
    public static func window(path: String, end: Int, lines: Int, chunkBytes: Int = 4 << 20, maxBytes: Int = 0) -> String {
        command(windowScript, arguments: [path, String(end), String(lines), String(chunkBytes)] + (maxBytes > 0 ? [String(maxBytes)] : []))
    }

    package static let windowScript = #"""
        f=$1
        e=$2
        n=$3
        c=$4
        g=0
        if [ "${5:-0}" -gt 0 ]; then c=$5; g=1; fi
        """# + "\n" + windowBody

    /// 視窗腳本設定好 `f`(檔案)、`e`(終點)、`n`(行數)、`c`(區塊大小)、`g`(1 = 不放大區塊)之後的本體;`window` 與 `open` 共用。
    package static let windowBody = #"""
        if [ ! -r "$f" ]; then exit 5; fi
        while :; do
        s=$((e - c))
        if [ "$s" -lt 0 ]; then s=0; fi
        if [ "$e" -gt "$s" ]; then
        r=$(tail -c +$((s + 1)) "$f" | head -c $((e - s)) | awk -v s="$s" -v t=$((e - s)) -v n="$n" -v g="$g" '{ p = q + length($0) + 1; if (p <= t) { if (NR > 1 || s == 0) { k++; a[k] = q }; z = p }; q = p } END { if (k < n && s > 0 && g == 0) { print "more" } else { i = k - n + 1; if (i < 1) i = 1; b = (k > 0) ? a[i] : z; print (s + b) " " (s + z) } }')
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

    /// 長駐追蹤腳本(#166,協定見 `TranscriptFollowProtocol`):一條 exec 通道服務所有追蹤中的路徑，閒置 `idleSeconds` 或總長 `totalSeconds` 到了以 exit 124 結束。
    ///
    /// 每個請求一行「游標 版本 錨點 路徑」(版本、錨點不知道時是 `-`),回應一則：`unchanged`、`error <exit code>`、
    /// `replaced <大小>`(變短或游標前 64 bytes 的 `cksum` 不符;版本相同也比對，同一秒換成同長的新檔才看得出來),或 `appended <大小> <版本>` 接著分段接著讀(#130)的行
    /// (格式同 `catchUp`;落後超過 `limit` 時這次讀到 `backlogLimit`),最後 `end <新游標> <錨點>`。版本是「修改時間秒數-大小」。
    package static func follow(
        limit: Int = TranscriptFollowProtocol.limit, backlogLimit: Int = TranscriptFollowProtocol.backlogLimit,
        idleSeconds: Int = HostScriptTimeLimit.followIdleSeconds, totalSeconds: Int = HostScriptTimeLimit.followTotalSeconds
    ) -> String {
        ([followInvocation] + [limit, backlogLimit, idleSeconds, totalSeconds].map { PosixShell.quote(String($0)) }).joined(separator: " ")
    }

    /// `follow` 參數之前的部分(Windows 方言以它認出追蹤腳本)。
    package static let followInvocation = prefix + PosixShell.quote(HostScriptTimeLimit.posix(followScript, seconds: "$4")) + " sh"

    /// 閒置時限：每收到一個請求就換一個新的 `purrdr_limit`(總長的那個由 `HostScriptTimeLimit.posix` 起)。
    /// HUP 也以 124 結束：CI 上閒置時限曾以 1 結束(推測是停住程序樹時孤兒程序群組收到的 HUP)。
    package static let followScript = #"""
        trap 'exit 124' HUP
        purrdr_anchor() {
        if [ "$2" -le 0 ]; then anchor=0; return; fi
        anchor_start=$(($2 - 64))
        if [ "$anchor_start" -lt 0 ]; then anchor_start=0; fi
        anchor=$(tail -c +$((anchor_start + 1)) "$1" | head -c $(($2 - anchor_start)) | cksum)
        anchor=${anchor%% *}
        }
        @OPENFUNCTIONS@
        purrdr_limit "$$" "$3" < /dev/null > /dev/null 2>&1 &
        idle_limit=$!
        while IFS= read -r request; do
        kill "$idle_limit" 2>/dev/null
        purrdr_limit "$$" "$3" < /dev/null > /dev/null 2>&1 &
        idle_limit=$!
        case $request in
        "open "*)
        purrdr_open_request "$request"
        continue
        ;;
        esac
        cursor=${request%% *}
        request=${request#* }
        known_stamp=${request%% *}
        request=${request#* }
        known_anchor=${request%% *}
        file=${request#* }
        if [ ! -e "$file" ]; then printf 'error 3\n'; continue; fi
        if [ ! -r "$file" ]; then printf 'error 5\n'; continue; fi
        size=$(wc -c < "$file")
        size=$((size + 0))
        stamp=$(date -r "$file" +%s 2>/dev/null)-$size
        if [ "$size" -lt "$cursor" ]; then printf 'replaced %s\n' "$size"; continue; fi
        if [ "$known_anchor" != - ]; then
        purrdr_anchor "$file" "$cursor"
        if [ "$anchor" != "$known_anchor" ]; then printf 'replaced %s\n' "$size"; continue; fi
        fi
        if [ "$stamp" = "$known_stamp" ]; then printf 'unchanged\n'; continue; fi
        limit=$1
        if [ $((size - cursor)) -gt "$1" ]; then limit=$2; fi
        end=$cursor
        if [ "$size" -gt "$cursor" ]; then
        end=$(tail -c +$((cursor + 1)) "$file" | head -c $((size - cursor)) | awk -v total=$((size - cursor)) -v limit="$limit" '{ next_end = taken + length($0) + 1; if (next_end > total || (next_end > limit && NR > 1)) exit; taken = next_end } END { print taken + 0 }')
        end=$((cursor + end))
        fi
        purrdr_anchor "$file" "$end"
        printf 'appended %s %s\n' "$size" "$stamp"
        if [ "$end" -gt "$cursor" ]; then
        tail -c +$((cursor + 1)) "$file" | head -c $((end - cursor)) | ANNOTATE | awk -v limit="$limit" '{ tab = index($0, "\t"); if (length($0) - tab > limit) $0 = substr($0, 1, tab + limit); print }'
        fi
        printf 'end %s %s\n' "$end" "$anchor"
        done
        """#.replacingOccurrences(of: "@OPENFUNCTIONS@", with: openFunctions).replacingOccurrences(of: "ANNOTATE", with: annotateAndStrip)

    /// 長駐追蹤通道上的「點進聊天」請求(#662):`open <種類> <行數> <maxBytes> <資料夾名或~> <id 或路徑>`(路徑在最後，可含空白)。
    /// 回應:成功是 `opened`、與一次性 `open` 指令相同的輸出(定位輸出、`openMarker`、視窗輸出)、最後一行 `openEnd <exit code>`;
    /// 定位失敗是 `error <exit code>`(3 缺席、4 不可搜尋、5 不可讀、6 有歧義、7 只有壓縮檔)。種類是 `TranscriptLocator.name`。
    /// 定位的片段是 `locateScript`(位置參數 `$1` id、`$2` 資料夾名),視窗是 `windowBody`,與一次性指令共用。
    package static func openRequest(_ location: TranscriptLocation, lines: Int, maxBytes: Int) -> String {
        let folder = location.locator.usesProjectFolder ? ClaudeTranscript.projectFolder(forCWD: location.cwd) : "~"
        return "open \(location.locator.name) \(lines) \(maxBytes) \(folder) \(location.reference.value)"
    }

    /// 回應「點進聊天」的第一行的關鍵字。
    package static let openedKeyword = "opened"

    /// 回應「點進聊天」的最後一行的關鍵字。
    package static let openEndKeyword = "openEnd"

    private static let openFunctions: String = {
        let branches = TranscriptLocator.all.map { "\($0.name))\n\(locateScript($0))\n;;" }.joined(separator: "\n")
        let head = #"""
            purrdr_locate() {
            case $purrdr_kind in
            """#
        let middle = #"""
            *) exit 127 ;;
            esac
            }
            purrdr_open() {
            located=$(purrdr_locate "$@")
            located_status=$?
            if [ "$located_status" -ne 0 ]; then printf 'error %s\n' "$located_status"; return; fi
            printf 'OPENED\n%s\n%s\n' "$located" OPENMARKER
            f=$(printf '%s\n' "$located" | sed -n 1p)
            e=$(printf '%s\n' "$located" | sed -n 2p)
            (
            n=$3
            c=$4
            g=1
            if [ "$c" -le 0 ]; then c=4194304; g=0; fi
            """#
        let tail = #"""
            )
            printf 'OPENEND %s\n' "$?"
            }
            purrdr_open_request() {
            open_rest=${1#open }
            purrdr_kind=${open_rest%% *}
            open_rest=${open_rest#* }
            open_lines=${open_rest%% *}
            open_rest=${open_rest#* }
            open_max=${open_rest%% *}
            open_rest=${open_rest#* }
            open_folder=${open_rest%% *}
            open_ref=${open_rest#* }
            if [ "$open_folder" = '~' ]; then open_folder=; fi
            purrdr_open "$open_ref" "$open_folder" "$open_lines" "$open_max"
            }
            """#
        return [head, branches, middle.replacingOccurrences(of: "OPENMARKER", with: openMarker).replacingOccurrences(of: "OPENED", with: openedKeyword), windowBody, tail.replacingOccurrences(of: "OPENEND", with: openEndKeyword)]
            .joined(separator: "\n")
    }()

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
        package var knownVersion: PreviewVersion?

        package init(key: String, type: String, value: String, extra: String = "", knownVersion: PreviewVersion? = nil) {
            self.key = key
            self.type = type
            self.value = value
            self.extra = extra
            self.knownVersion = knownVersion
        }

        /// id 或路徑不安全時為 `nil`(不進 shell,R-I12)。
        package init?(_ request: PreviewRequest) {
            let location = request.target.location
            guard location.isSafe else { return nil }
            self.init(
                key: request.key, type: location.locator.name, value: location.reference.value,
                extra: location.locator.usesProjectFolder ? ClaudeTranscript.projectFolder(forCWD: location.cwd) : ""
            )
            knownVersion = request.knownVersion
        }
    }

    /// 列表預覽：每個請求印「標記 key」,讀得到再印「標記@ key 範圍 版本」與內容(unchanged 不印、appended 只印附加、whole 印檔尾)。
    /// 參數：標記，接著每個請求五個(key、定位方式、id 或路徑、Claude 的資料夾名、已知版本)。
    package static func previews(marker: String, entries: [PreviewEntry]) -> String {
        // 腳本以空字串表示沒有已知版本。
        command(previewsScript, arguments: [marker] + entries.flatMap { [$0.key, $0.type, $0.value, $0.extra, $0.knownVersion?.value ?? ""] })
    }

    /// 列表預覽每個請求最多讀的檔尾 bytes(與 `previewsScript` 的 `tail -c` 相同;估算期限用)。
    package static let previewBytes = 48_000

    package static let previewsScript = #"""
        m=$1
        shift
        while [ $# -ge 5 ]; do
        printf '%s %s\n' "$m" "$1"
        (
        y=$1
        t=$2
        i=$3
        p=$4
        known_version=$5
        case $t in
        @BRANCHES@
        *)
        f=$i
        ;;
        esac
        if [ -r "$f" ]; then
        purrdr_anchor() {
        if [ "$1" -le 0 ]; then anchor=0; return; fi
        anchor_start=$(($1 - 64))
        if [ "$anchor_start" -lt 0 ]; then anchor_start=0; fi
        anchor=$(tail -c +$((anchor_start + 1)) "$f" | head -c $(($1 - anchor_start)) | cksum)
        anchor=${anchor%% *}
        }
        size=$(wc -c < "$f")
        size=$((size + 0))
        purrdr_anchor "$size"
        version="$(date -r "$f" +%s 2>/dev/null)-$size $anchor"
        range=whole
        if [ -n "$known_version" ]; then
        known_size=${known_version%% *}
        known_size=${known_size##*-}
        case $known_size in
        ''|*[!0-9]*) known_size=-1 ;;
        esac
        if [ "$known_version" = "$version" ]; then
        range=unchanged
        elif [ "$known_size" -ge 0 ] && [ "$known_size" -lt "$size" ] && [ $((size - known_size)) -le 48000 ]; then
        purrdr_anchor "$known_size"
        if [ "$known_version" = "${known_version% *} $anchor" ] && { [ "$known_size" -eq 0 ] || [ "$(tail -c +"$known_size" "$f" | head -c 1 | wc -l)" -eq 1 ]; }; then range=appended; fi
        fi
        fi
        printf '%s@ %s %s %s\n' "$m" "$y" "$range" "$version"
        case $range in
        appended)
        tail -c +$((known_size + 1)) "$f" | head -c $((size - known_size)) | @STRIP@
        printf '\n'
        ;;
        whole)
        case $t in
        @HEADERKINDS@)
        printf '%s! %s\n' "$m" "$y"
        head -n 2 "$f" | @STRIP@
        printf '\n%s %s\n' "$m" "$y"
        ;;
        esac
        tail -c 48000 "$f" | @STRIP@
        printf '\n'
        ;;
        esac
        fi
        )
        shift 5
        done
        """#
            .replacingOccurrences(of: "@BRANCHES@", with: TranscriptLocator.all.filter { $0.resolver != TranscriptLocator.reportedPathResolver }.map { "\($0.name))\n\($0.resolver)\n;;" }.joined(separator: "\n"))
            .replacingOccurrences(of: "@HEADERKINDS@", with: TranscriptLocator.all.filter(\.readsHeader).map(\.name).joined(separator: "|"))
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
