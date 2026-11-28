import Foundation

/// 對話紀錄在主機上的位置規則(行為規格 §4):一段 POSIX 片段由 `$i`(session id 或回報的路徑)決定 `$f`,
/// 找不到是 exit 3(缺席)、資料夾不可搜尋 4、不只一個候選 6(有歧義)、只有壓縮檔 7。
///
/// 位置規則以名稱為身分(`name` 同時是列表預覽腳本與 Windows 方言的定位種類)。核心的主機連線只認得這個通用的
/// 定位請求(`TranscriptRequest.locate`),不分 Agent 種類(ADR-0013)。
public struct TranscriptLocator: Sendable, Hashable {
    /// 定位種類(預覽腳本的分支、Windows 腳本的 `PFind` 種類)。
    public let name: String
    /// Windows 方言的找檔種類;回報路徑的兩種定位都是 `path`。
    package let lookupName: String
    /// 由 `$i` 決定 `$f` 的 POSIX 片段(預覽與一般定位共用)。
    package let resolver: String
    /// 這種位置規則的完整定位腳本(自己處理探測與輸出);`nil` 用 `resolver` 組成通用腳本。Claude 另有 worktree 後備。
    package let customLocateScript: String?
    /// 定位參數除了 id 還要帶 cwd 轉成的資料夾名。
    public let usesProjectFolder: Bool
    /// 找到的檔案要再檢查前幾行(header)才算這個 session(Pi／OMP、Codex);`nil` 不讀 header。
    /// 參數是檔案前兩行之後的 header 行與預期的 id(路徑參照沒有 id)。
    let headerCheck: (@Sendable (_ header: [String], _ expectedID: String?) -> Bool)?
    /// 以 id 找到的路徑要符合的形狀;`nil` 不檢查。
    let pathCheck: (@Sendable (_ path: String, _ id: String) -> Bool)?

    public var readsHeader: Bool { headerCheck != nil }

    /// Windows 對話紀錄腳本裡找檔的 PowerShell 函式定義(一行);沿用回報路徑的位置規則沒有自己的函式(`nil`)。
    package let powershellFunction: String?
    /// `PFind` 裡這個種類呼叫上面函式的運算式(`$i` id、`$p` 資料夾名);`nil` 走預設(`$i` 本身就是路徑)。
    package let powershellFindCall: String?

    /// 回報路徑的位置規則:`$i` 本身就是檔案路徑。
    package static let reportedPathResolver = "f=$i"

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    init(
        name: String, lookupName: String? = nil, resolver: String, customLocateScript: String? = nil, usesProjectFolder: Bool = false,
        headerCheck: (@Sendable (_ header: [String], _ expectedID: String?) -> Bool)? = nil,
        pathCheck: (@Sendable (_ path: String, _ id: String) -> Bool)? = nil,
        powershellFunction: String? = nil, powershellFindCall: String? = nil
    ) {
        self.name = name
        self.lookupName = lookupName ?? name
        self.resolver = resolver
        self.customLocateScript = customLocateScript
        self.usesProjectFolder = usesProjectFolder
        self.headerCheck = headerCheck
        self.pathCheck = pathCheck
        self.powershellFunction = powershellFunction
        self.powershellFindCall = powershellFindCall
    }

    /// `<Claude 設定目錄>/projects/<cwd 轉成的資料夾名>/<id>.jsonl`,含 worktree 後備(§4.1)。
    public static let claude = TranscriptLocator(
        name: "claude",
        // Claude 的定位腳本另有 worktree 後備(`TranscriptCommand.locate(sessionID:projectFolder:)`);預覽只看預期路徑。
        resolver: #"f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$p/$i.jsonl""#,
        customLocateScript: TranscriptCommand.claudeLocateScript,
        usesProjectFolder: true,
        powershellFunction: #"function PClaude([string]$i,[string]$p){Join-Path (Join-Path (Join-Path (PHome $env:CLAUDE_CONFIG_DIR '.claude') 'projects') $p) "$i.jsonl"}"#,
        powershellFindCall: "PClaude $i $p"
    )

    /// 在 `${GROK_HOME:-$HOME/.grok}/sessions` 下找名稱等於 id 的資料夾(§4.3)。
    public static let grok = TranscriptLocator(
        name: "grok",
        resolver: grokResolver,
        pathCheck: { path, id in TranscriptReader.hasComponents(path, "\(id)/updates.jsonl") },
        powershellFunction: #"function PGrok([string]$i){$h=Join-Path (PHome $env:GROK_HOME '.grok') 'sessions';if(-not [IO.Directory]::Exists($h)){PFail 3};$g=@(PList $h -Dir|%{PList $_.FullName -Dir}|?{$_.Name -ceq $i});if($g.Count -eq 0){PFail 3};if($g.Count -gt 1){PFail 6};Join-Path $g[0].FullName 'updates.jsonl'}"#,
        powershellFindCall: "PGrok $i"
    )

    /// `$HOME/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`(§4.4)。
    public static let antigravity = TranscriptLocator(
        name: "agy",
        resolver: antigravityResolver,
        powershellFunction: #"function PAntigravity([string]$i){Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain\$i\.system_generated\logs\transcript.jsonl"}"#,
        powershellFindCall: "PAntigravity $i"
    )

    /// 在 Pi／OMP 的 sessions 資料夾找 `*_<id>.jsonl` 或 `<id>.jsonl`(§4.5);讀前檢查 header。
    public static let piJournal = TranscriptLocator(
        name: "pi",
        resolver: piJournalResolver,
        headerCheck: { header, id in PiJournalParser.headerMatches(header, expectedID: id) },
        powershellFunction: #"function PPiJournal([string]$i){$c=$env:PI_CONFIG_DIR;if(-not $c){$c='.omp'};$r=Join-Path $env:USERPROFILE $c;$ds=@($env:PI_CODING_AGENT_SESSION_DIR,(Join-Path (PHome $env:PI_CODING_AGENT_DIR '.pi\agent') 'sessions'),(Join-Path $r 'agent\sessions'),(Join-Path $r 'agent\profiles'));if($env:XDG_DATA_HOME){$ds+=Join-Path $env:XDG_DATA_HOME 'omp'};$g=@($ds|?{$_ -and [IO.Directory]::Exists($_)}|%{PList $_ -Depth 3}|?{$_.Name -ceq "$i.jsonl" -or $_.Name.EndsWith("_$i.jsonl",[StringComparison]::Ordinal)}|%{$_.FullName}|Sort-Object -Unique);if($g.Count -eq 0){PFail 3};if($g.Count -gt 1){PFail 6};$g[0]}"#,
        powershellFindCall: "PPiJournal $i"
    )

    /// 在 `${CODEX_HOME:-$HOME/.codex}` 的 sessions 與 archived_sessions 下找 `rollout-*-<id>.jsonl`(§4.2);讀前檢查 header。
    public static let codex = TranscriptLocator(
        name: "codex",
        resolver: codexResolver,
        headerCheck: { header, id in
            guard let id, let first = header.first else { return false }
            return CodexTranscriptParser.headerMatches(first, expectedID: id)
        },
        // 路徑必須是 `-<id>(_<rolloutId>)?.jsonl`;第一行是這個 session 的 session_meta(§4.2)。
        pathCheck: { path, id in TranscriptReader.isCodexRollout(path, id: id) },
        powershellFunction: #"function PCodex([string]$i){$h=PHome $env:CODEX_HOME '.codex';$g=@();$z=$false;foreach($n in 'sessions','archived_sessions'){$d=Join-Path $h $n;if([IO.Directory]::Exists($d)){foreach($e in (PList $d)){$m=$e.Name;if($m.StartsWith('rollout-',[StringComparison]::Ordinal)){if($m.EndsWith("-$i.jsonl",[StringComparison]::Ordinal) -or ($m -cmatch "-$i`_[^\\]*\.jsonl$")){$g+=$e.FullName}elseif($m.EndsWith("-$i.jsonl.zst",[StringComparison]::Ordinal) -or ($m -cmatch "-$i`_[^\\]*\.jsonl\.zst$")){$z=$true}}}}};$g=@($g|Sort-Object -Unique);if($g.Count -eq 0){if($z){PFail 7};PFail 3};if($g.Count -gt 1){PFail 6};$g[0]}"#,
        powershellFindCall: "PCodex $i"
    )

    /// integration 以路徑回報的對話紀錄。`headerCheck` 與同一個 Agent 以 id 定位時相同(Pi／OMP 的路徑也要檢查 header)。
    public static func reportedPath(headerCheck: (@Sendable (_ header: [String], _ expectedID: String?) -> Bool)? = nil) -> TranscriptLocator {
        headerCheck == nil ? Self.reportedPathNoHeader : Self.reportedPathWithHeader
    }

    private static let reportedPathNoHeader = TranscriptLocator(name: "path", resolver: reportedPathResolver)
    private static let reportedPathWithHeader = TranscriptLocator(
        name: "pipath", lookupName: "path", resolver: reportedPathResolver,
        headerCheck: { header, id in PiJournalParser.headerMatches(header, expectedID: id) }
    )

    /// 全部的位置規則:預覽腳本、Windows 的定位腳本與要讀 header 的名單都依它產生(同樣讀 header 的種類排在一起)。
    package static let all: [TranscriptLocator] = [
        .claude, .grok, .antigravity, .piJournal, reportedPath(headerCheck: { _, _ in true }), .codex, reportedPath(),
    ]

    private static let grokResolver = #"""
            h=${GROK_HOME:-$HOME/.grok}/sessions
            if [ ! -d "$h" ]; then exit 3; fi
            if [ ! -x "$h" ]; then exit 4; fi
            g=$(find "$h" -mindepth 2 -maxdepth 2 -type d -name "$i" -print 2>/dev/null)
            if [ -z "$g" ]; then exit 3; fi
            k=$(printf '%s\n' "$g" | wc -l)
            if [ $((k + 0)) -gt 1 ]; then exit 6; fi
            f="$g/updates.jsonl"
            """#
    private static let antigravityResolver = #"f="$HOME/.gemini/antigravity-cli/brain/$i/.system_generated/logs/transcript.jsonl""#
    private static let piJournalResolver = #"""
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
    private static let codexResolver = #"""
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
}
