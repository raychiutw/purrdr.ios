import Foundation
import PurrdrCore

/// Windows 主機的 PowerShell 腳本(行為規格 §11.2):與 POSIX 版本(`TranscriptCommand`、`HostUploadCommand`、
/// `HostFolderCommand`、`NewChatFolders`)**輸出格式與 exit code 相同**,client 的解析不分主機。
///
/// 通則：
/// - 參數放在開頭的 `$a=@('…',…)`(PowerShell 引號),不拼進腳本本體。
/// - 輸出一律經 `[Console]::OpenStandardOutput()`(`PWrite`)以 UTF-8 bytes 寫出、換行是 `\n`:不經 PowerShell 管線
///   (會轉碼、會加 `\r\n`)。檔案以 bytes 讀，游標是 byte 數。
/// - 家目錄是 `%USERPROFILE%`;檔案以 `FileShare.ReadWrite|Delete` 開(agent 正在寫的檔案也讀得到)。
/// - exit code 與 POSIX 相同:`3` 缺席、`4` 資料夾不可搜尋、`5` 檔案不可讀、`6` 有歧義、`7` 只有壓縮檔。
enum WindowsScripts {
    static func arguments(_ values: [String]) -> String {
        "$a=@(" + values.map(PowerShell.quote).joined(separator: ",") + ")"
    }

    /// 所有腳本共用的開頭：不印進度(否則 PowerShell 把它序列化成 CLIXML 寫到 stderr)、錯誤即停、UTF-8 輸出。
    static let prelude = #"""
        $ProgressPreference='SilentlyContinue'
        $ErrorActionPreference='Stop'
        $u=New-Object Text.UTF8Encoding $false
        [Console]::OutputEncoding=$u
        $o=[Console]::OpenStandardOutput()
        function PWrite([string]$s){$b=$u.GetBytes($s);$o.Write($b,0,$b.Length)}
        """#

    // MARK: - 對話紀錄(行為規格 §4.7)

    /// 讀檔與輸出的共用函式。
    ///
    /// 函式一律以 `P` 開頭：PowerShell 的 alias 優先於函式，短名稱會撞到內建 alias(`ls` 是 Get-ChildItem,
    /// `rd` 甚至是 Remove-Item)。
    ///
    /// - `PStrip`:剝除圖片(與 POSIX 的 `sed` 相同的兩個規則，逐行套用)。
    /// - `PLines`:把 `$b[$i..$t)` 裡**完整**的行(以 `\n` 結尾)印成「原始 byte 長度 TAB 剝除後的行」。
    /// - `PRead`:從 `$s` 讀 `$n` bytes(檔案較短時讀到結尾)。
    /// - `PCatchUpLines`:分段追趕(#130)印出 `$p` 之後累計不超過 `$m` 的完整行，回傳新游標。
    /// - `PAnchor`:`$e` 之前 64 bytes 的 SHA-256 前 8 bytes(換檔判斷，追蹤用)。
    /// - `PFail`:丟出帶 exit code 的錯誤，由呼叫處決定要結束還是略過(列表預覽一個失敗不影響其他)。
    static let transcriptFunctions = #"""
        function PStrip([string]$s){$s=[regex]::Replace($s,'"[A-Za-z0-9+/=]{128,}"','""');[regex]::Replace($s,'"data:[^"]*;base64,[^"]*"','""')}
        function PLines([byte[]]$b,[int]$i,[int]$t){while($i -lt $t){$j=[Array]::IndexOf($b,[byte]10,$i,$t-$i);if($j -lt 0){break};PWrite ("$($j-$i)`t"+(PStrip $u.GetString($b,$i,$j-$i))+"`n");$i=$j+1}}
        function POpen([string]$f){[IO.File]::Open($f,'Open','Read','ReadWrite,Delete')}
        function PRead($h,[long]$s,[long]$n){$b=New-Object byte[] $n;[void]$h.Seek($s,'Begin');$t=0;while($t -lt $n){$r=$h.Read($b,$t,$n-$t);if($r -le 0){break};$t+=$r};if($t -lt $n){$c=New-Object byte[] $t;[Array]::Copy($b,$c,$t);$b=$c};,$b}
        function PCatchUpLines($h,[long]$p,[long]$z,[long]$m){$r=$z-$p;$n=[Math]::Min($r,$m);while($true){$b=PRead $h $p $n;$j=[Array]::LastIndexOf($b,[byte]10);if($j -ge 0 -or $n -ge $r){break};$n=[Math]::Min($r,$n*2)};if($n -gt $m){$j=[Array]::IndexOf($b,[byte]10);if($j -ge 0){$c=$u.GetBytes((PStrip $u.GetString($b,0,$j)));PWrite "$j`t";$o.Write($c,0,[int][Math]::Min($c.Length,$m));PWrite "`n";return $p+$j+1}}elseif($j -ge 0){PLines $b 0 ($j+1);return $p+$j+1};$p}
        function PAnchor($h,[long]$e){if($e -le 0){return '0'};$x=[Math]::Max([long]0,$e-64);$b=PRead $h $x ($e-$x);-join ([Security.Cryptography.SHA256]::Create().ComputeHash($b)[0..7]|%{$_.ToString('x2')})}
        function PFail([int]$c){throw "purrdr-exit:$c"}
        function PCode($e){if("$($e.Exception.Message)" -match '^purrdr-exit:(\d+)$'){[int]$Matches[1]}else{1}}
        function PProbe([string]$f){$d=[IO.Path]::GetDirectoryName($f);if(-not [IO.Directory]::Exists($d)){PFail 3};if(-not [IO.File]::Exists($f)){try{[void][IO.Directory]::GetFileSystemEntries($d)}catch{PFail 4};PFail 3};try{$h=POpen $f;$z=$h.Length;$h.Close()}catch{PFail 5};$z}
        function PHead2([string]$f){$h=POpen $f;$n=0;$k=0;$c=New-Object byte[] 65536;$m=New-Object IO.MemoryStream;while($k -lt 2){$r=$h.Read($c,0,$c.Length);if($r -le 0){break};$e=$r;for($x=0;$x -lt $r;$x++){if($c[$x] -eq 10){$k++;if($k -eq 2){$e=$x+1;break}}};$m.Write($c,0,$e)};$h.Close();$m.ToArray()}
        function PHome([string]$v,[string]$d){if($v){$v}else{Join-Path $env:USERPROFILE $d}}
        function PClaude([string]$i,[string]$p){Join-Path (Join-Path (Join-Path (PHome $env:CLAUDE_CONFIG_DIR '.claude') 'projects') $p) "$i.jsonl"}
        function PList([string]$d,[switch]$Dir,[int]$Depth=-1){try{if($Depth -ge 0){@(Get-ChildItem -LiteralPath $d -Force -Recurse -Depth $Depth -File)}elseif($Dir){@(Get-ChildItem -LiteralPath $d -Force -Directory)}else{@(Get-ChildItem -LiteralPath $d -Force -Recurse -File)}}catch{PFail 4}}
        function PGrok([string]$i){$h=Join-Path (PHome $env:GROK_HOME '.grok') 'sessions';if(-not [IO.Directory]::Exists($h)){PFail 3};$g=@(PList $h -Dir|%{PList $_.FullName -Dir}|?{$_.Name -ceq $i});if($g.Count -eq 0){PFail 3};if($g.Count -gt 1){PFail 6};Join-Path $g[0].FullName 'updates.jsonl'}
        function PAntigravity([string]$i){Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain\$i\.system_generated\logs\transcript.jsonl"}
        function PPiJournal([string]$i){$c=$env:PI_CONFIG_DIR;if(-not $c){$c='.omp'};$r=Join-Path $env:USERPROFILE $c;$ds=@($env:PI_CODING_AGENT_SESSION_DIR,(Join-Path (PHome $env:PI_CODING_AGENT_DIR '.pi\agent') 'sessions'),(Join-Path $r 'agent\sessions'),(Join-Path $r 'agent\profiles'));if($env:XDG_DATA_HOME){$ds+=Join-Path $env:XDG_DATA_HOME 'omp'};$g=@($ds|?{$_ -and [IO.Directory]::Exists($_)}|%{PList $_ -Depth 3}|?{$_.Name -ceq "$i.jsonl" -or $_.Name.EndsWith("_$i.jsonl",[StringComparison]::Ordinal)}|%{$_.FullName}|Sort-Object -Unique);if($g.Count -eq 0){PFail 3};if($g.Count -gt 1){PFail 6};$g[0]}
        function PCodex([string]$i){$h=PHome $env:CODEX_HOME '.codex';$g=@();$z=$false;foreach($n in 'sessions','archived_sessions'){$d=Join-Path $h $n;if([IO.Directory]::Exists($d)){foreach($e in (PList $d)){$m=$e.Name;if($m.StartsWith('rollout-',[StringComparison]::Ordinal)){if($m.EndsWith("-$i.jsonl",[StringComparison]::Ordinal) -or ($m -cmatch "-$i`_[^\\]*\.jsonl$")){$g+=$e.FullName}elseif($m.EndsWith("-$i.jsonl.zst",[StringComparison]::Ordinal) -or ($m -cmatch "-$i`_[^\\]*\.jsonl\.zst$")){$z=$true}}}}};$g=@($g|Sort-Object -Unique);if($g.Count -eq 0){if($z){PFail 7};PFail 3};if($g.Count -gt 1){PFail 6};$g[0]}
        function PFind([string]$t,[string]$i,[string]$p){switch -CaseSensitive($t){'claude'{PClaude $i $p}'grok'{PGrok $i}'agy'{PAntigravity $i}'pi'{PPiJournal $i}'codex'{PCodex $i}default{$i}}}
        function PRunBlock([scriptblock]$k){try{& $k}catch{$o.Flush();exit (PCode $_)};$o.Flush()}
        """#

    static func transcript(_ body: String, arguments values: [String]) -> String {
        [prelude, arguments(values), transcriptFunctions, body].joined(separator: "\n")
    }

    /// Claude Code:預期路徑不在時，在所有專案資料夾找同名檔(worktree)。參數:session id、資料夾名。
    static let claudeLocate = #"""
        PRunBlock {
        $c=Join-Path (PHome $env:CLAUDE_CONFIG_DIR '.claude') 'projects'
        $f=PClaude $a[0] $a[1]
        if(-not [IO.File]::Exists($f) -and [IO.Directory]::Exists($c)){$g=@(PList $c -Dir|%{Join-Path $_.FullName "$($a[0]).jsonl"}|?{[IO.File]::Exists($_)});if($g.Count -gt 0){$f=$g[0]}}
        PWrite "$f`n"
        $z=PProbe $f
        PWrite "$z`n"
        }
        """#

    /// 其他 agent:印路徑與大小;`header` 時再印檔案前兩行(原樣)。參數:session id 或路徑。
    static func locate(type: String, header: Bool) -> String {
        """
        PRunBlock {
        $f=PFind \(PowerShell.quote(type)) $a[0] ''
        $z=PProbe $f
        PWrite "$f`n$z`n"
        \(header ? "$x=PHead2 $f;$o.Write($x,0,$x.Length)" : "")
        }
        """
    }

    /// 視窗：以 `end` 為終點往前取恰好 `lines` 行完整的行(演算法與 POSIX 版相同)。參數：路徑、終點、行數、區塊大小、(選用)byte 上限(#356,大於 0 時不放大區塊)。
    static let window = #"""
        PRunBlock {
        $f=$a[0];$e=[long]$a[1];$n=[int]$a[2];$c=[long]$a[3];$g=$false
        if($a.Count -gt 4 -and [long]$a[4] -gt 0){$c=[long]$a[4];$g=$true}
        try{$h=POpen $f}catch{PFail 5}
        while($true){
        $s=[Math]::Max([long]0,$e-$c);$st=New-Object Collections.Generic.List[long];$z=[long]0
        if($e -gt $s){$b=PRead $h $s ($e-$s);$q=0;$known=($s -eq 0);$i=0;while($i -lt $b.Length){$j=[Array]::IndexOf($b,[byte]10,$i);if($j -lt 0){break};if($known){$st.Add($q)};$known=$true;$z=$j+1;$q=$j+1;$i=$j+1}}
        if($st.Count -lt $n -and $s -gt 0 -and -not $g){$c=$c*4;continue}
        $k=[Math]::Max(0,$st.Count-$n);if($st.Count -gt 0){$x=$s+$st[$k]}else{$x=$s+$z};$y=$s+$z
        break
        }
        PWrite "$x $y`n"
        if($y -gt $x){$b=PRead $h $x ($y-$x);PLines $b 0 $b.Length}
        $h.Close()
        }
        """#

    /// 追蹤：印目前大小;比游標大且落差 ≤ 上限時，再印游標之後完整的行。參數：路徑、游標、上限。
    static let tail = #"""
        PRunBlock {
        $f=$a[0];$p=[long]$a[1];$m=[long]$a[2]
        $z=PProbe $f
        PWrite "$z`n"
        if($z -gt $p -and ($z-$p) -le $m){$h=POpen $f;$b=PRead $h $p ($z-$p);$h.Close();PLines $b 0 $b.Length}
        }
        """#

    /// 分段追趕(#130):印目前大小;比游標大時，再印游標之後累計不超過上限的完整行(即使後面還有)。
    /// 上限內沒有完整行(第一行就超過上限)時，區塊加倍直到找到第一個換行，只印那一行，剝除圖片後的內容截短到上限
    /// (與 POSIX 相同：原始長度照實印，游標照樣前進，傳輸量不超過上限)。參數：路徑、游標、上限。
    static let catchUp = #"""
        PRunBlock {
        $f=$a[0];$p=[long]$a[1];$m=[long]$a[2]
        $z=PProbe $f
        PWrite "$z`n"
        if($z -gt $p){$h=POpen $f;[void](PCatchUpLines $h $p $z $m);$h.Close()}
        }
        """#

    /// 長駐追蹤(#167,輸出同 `TranscriptCommand.followScript`):stub 讀完腳本後，從同一個 reader(`$s`,原始 handle,#77)
    /// 繼續讀請求行「游標 版本 錨點 路徑」。版本是「修改時間 ticks-大小」。每個請求把時限延到閒置秒數後(不超過總長)。
    /// 參數(`$a`):上限、追趕上限、閒置秒數、總長秒數。`$s`、`$o` 由 stub 的開頭提供(所有腳本共用的短名)。
    static let follow = #"""
        $purrdrEnd=[DateTime]::UtcNow.AddSeconds([int]$a[3])
        function PIdle{$idleUntil=[DateTime]::UtcNow.AddSeconds([int]$a[2]);if($idleUntil -gt $purrdrEnd){$idleUntil=$purrdrEnd};$purrdrLimit.At=$idleUntil}
        PIdle
        while(($request=$s.ReadLine()) -ne $null){
        PIdle
        $handle=$null
        try{
        $fields=$request.Split([char]' ',4);$cursor=[long]$fields[0];$knownStamp=$fields[1];$knownAnchor=$fields[2];$file=$fields[3]
        if(-not [IO.File]::Exists($file)){PWrite "error 3`n"}
        else{
        try{$handle=POpen $file}catch{}
        if(-not $handle){PWrite "error 5`n"}
        else{
        $size=$handle.Length;$stamp="$([IO.File]::GetLastWriteTimeUtc($file).Ticks)-$size"
        if($size -lt $cursor -or ($knownAnchor -cne '-' -and (PAnchor $handle $cursor) -cne $knownAnchor)){PWrite "replaced $size`n"}
        elseif($stamp -ceq $knownStamp){PWrite "unchanged`n"}
        else{$limit=[long]$a[0];if(($size-$cursor) -gt $limit){$limit=[long]$a[1]};PWrite "appended $size $stamp`n";$end=$cursor;if($size -gt $cursor){$end=PCatchUpLines $handle $cursor $size $limit};PWrite "end $end $(PAnchor $handle $end)`n"}
        }
        }
        }catch{PWrite "error 5`n"}finally{if($handle){$handle.Close()}}
        $o.Flush()
        }
        $o.Flush()
        exit 0
        """#

    /// 列表預覽(格式同 POSIX 的 `TranscriptCommand.previewsScript`):每個請求「標記 key」,找得到可讀的檔再印「標記@ key 範圍 版本」
    /// (版本是「修改時間 ticks-大小 錨點」),`unchanged` 不印內容、`appended` 印已知版本之後附加的部分、`whole` 印剝除圖片後的檔尾
    /// 48,000 bytes(Pi／OMP、Codex 先印「標記! key」與前兩行)。每個請求各自 try:一個檔不在或有歧義不影響其他。
    /// 參數：標記，接著每個請求五個(key、種類、id 或路徑、資料夾名、已知版本或空字串)。
    static let previews = #"""
        $marker=$a[0]
        for($index=1;$index+4 -lt $a.Count;$index+=5){
        $key=$a[$index];$kind=$a[$index+1];$knownVersion=$a[$index+4]
        PWrite "$marker $key`n"
        $handle=$null
        try{
        $file=PFind $kind $a[$index+2] $a[$index+3]
        $handle=POpen $file
        $size=$handle.Length;$version="$([IO.File]::GetLastWriteTimeUtc($file).Ticks)-$size $(PAnchor $handle $size)";$range='whole'
        if($knownVersion){
        $knownStamp=$knownVersion.Split([char]' ')[0];[long]$knownSize=-1
        if(-not [long]::TryParse($knownStamp.Substring($knownStamp.LastIndexOf('-')+1),[ref]$knownSize)){$knownSize=-1}
        if($knownVersion -ceq $version){$range='unchanged'}
        elseif($knownSize -ge 0 -and $knownSize -lt $size -and ($size-$knownSize) -le 48000 -and "$knownStamp $(PAnchor $handle $knownSize)" -ceq $knownVersion -and ($knownSize -eq 0 -or (PRead $handle ($knownSize-1) 1)[0] -eq 10)){$range='appended'}
        }
        PWrite "$marker@ $key $range $version`n"
        if($range -ceq 'appended'){$bytes=PRead $handle $knownSize ($size-$knownSize);PWrite ((($u.GetString($bytes) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n"}
        elseif($range -ceq 'whole'){
        if('pi','pipath','codex' -ccontains $kind){PWrite "$marker! $key`n";$header=PHead2 $file;PWrite ((($u.GetString($header) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n$marker $key`n"}
        $start=[Math]::Max([long]0,$size-48000);$bytes=PRead $handle $start ($size-$start)
        PWrite ((($u.GetString($bytes) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n"
        }
        }catch{}finally{if($handle){$handle.Close()}}
        }
        $o.Flush()
        """#

    /// 找 subagent:`<session>\subagents\agent-*.meta.json` 中含呼叫 id 的，印路徑與內容(去掉 `\n`)。參數:session 資料夾、呼叫 id。
    static let findSubagent = #"""
        PRunBlock {
        $d=Join-Path $a[0] 'subagents'
        if(-not [IO.Directory]::Exists($d)){PFail 3}
        foreach($e in @(PList $d -Depth 0|?{$_.Name -clike 'agent-*.meta.json'})){$x=[IO.File]::ReadAllText($e.FullName,$u);if($x.Contains($a[1])){PWrite "$($e.FullName)`n$($x.Replace("`n",''))`n"}}
        }
        """#

    /// 讀 workflow 進度:先印「種類 checksum」(SHA-256 與大小);與參數 3 相同就不印內容。參數:session 資料夾、run id、上次的值。
    static let readWorkflow = #"""
        PRunBlock {
        $r=Join-Path $a[0] "workflows\$($a[1]).json";$j=Join-Path $a[0] "subagents\workflows\$($a[1])\journal.jsonl"
        if([IO.File]::Exists($r)){$k='run';$f=$r}elseif([IO.File]::Exists($j)){$k='journal';$f=$j}else{PFail 3}
        try{$h=POpen $f;$b=PRead $h 0 $h.Length;$h.Close()}catch{PFail 5}
        $c=-join ([Security.Cryptography.SHA256]::Create().ComputeHash($b)|%{$_.ToString('x2')})
        PWrite "$k $c $($b.Length)`n"
        if("$k $c $($b.Length)" -cne $a[2]){$o.Write($b,0,$b.Length)}
        }
        """#

    /// 委派是否結束：父對話紀錄裡含任一 id 的行。先印這些行(剝圖後)的 checksum,與參數 4 相同就不印內容。
    /// 參數：路徑、id、id、上次的值。
    static let delegationLines = #"""
        PRunBlock {
        try{$h=POpen $a[0];$b=PRead $h 0 $h.Length;$h.Close()}catch{PFail 5}
        $l=@();$i=0;while($i -lt $b.Length){$j=[Array]::IndexOf($b,[byte]10,$i);if($j -lt 0){$j=$b.Length};$x=$u.GetString($b,$i,$j-$i);if($x.Contains($a[1]) -or $x.Contains($a[2])){$l+=,@(($j-$i),$x)};$i=$j+1}
        $c=-join ([Security.Cryptography.SHA256]::Create().ComputeHash($u.GetBytes((($l|%{(PStrip $_[1])+"`n"}) -join '')))|%{$_.ToString('x2')})
        PWrite "$c`n"
        if($c -cne $a[3]){foreach($x in $l){PWrite "$($x[0])`t$(PStrip $x[1])`n"}}
        }
        """#

    // MARK: - 上傳(bytes 走 stdin,ADR-0003)

    /// 上傳到主機(圖片與一般檔案)到 `%TEMP%\purrdr-uploads`(與主機服務共用):與 POSIX 版相同的檢查與 exit code(64 檔名、71 建立失敗、72 讀 stdin、
    /// 73 已存在、75 大小不符)。先寫隱藏的暫存檔，大小相同才改名(改名不覆寫);刪掉新、舊資料夾裡 7 天前的檔案，舊的 `%USERPROFILE%\.purrdr\uploads` 空了就移除。參數：檔名、大小。
    /// `%TEMP%` 在使用者設定檔資料夾底下，繼承它的 ACL(只有本人、SYSTEM 與 Administrators);上傳資料夾是 reparse point(symlink、junction)時失敗。
    static let hostUpload = #"""
        $n=$a[0];$z=[long]$a[1]
        \#(uploadLimit(transferSizeArgument: 1))
        if($n -cnotmatch '^[A-Za-z0-9-][A-Za-z0-9.-]*$'){exit 64}
        $d=Join-Path $env:TEMP '\#(HostServiceProtocol.uploadFolder)'
        try{[void][IO.Directory]::CreateDirectory($d);if((Get-Item -LiteralPath $d -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){exit 71}}catch{exit 71}
        $t=Join-Path $d ('.upload.'+[Guid]::NewGuid().ToString('N'));$purrdrLimit.Files+=$t
        $p=Join-Path $d $n
        try{
        try{$w=[IO.File]::Open($t,'CreateNew','Write','Delete')}catch{exit 71}
        try{PReceive $w $z}catch{exit 72}finally{$w.Close()}
        if((New-Object IO.FileInfo $t).Length -ne $z){exit 75}
        if(Test-Path -LiteralPath $p){exit 73}
        try{[IO.File]::Move($t,$p)}catch{if(Test-Path -LiteralPath $p){exit 73};exit 71}
        $t=$null
        $old=(Get-Date).AddDays(-7);Get-ChildItem -LiteralPath $d -Force -File|?{$_.LastWriteTime -lt $old}|Remove-Item -Force -ErrorAction SilentlyContinue
        $legacy=Join-Path $env:USERPROFILE '.purrdr\uploads'
        if([IO.Directory]::Exists($legacy) -and -not ((Get-Item -LiteralPath $legacy -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        Get-ChildItem -LiteralPath $legacy -Force -File|?{$_.LastWriteTime -lt $old}|Remove-Item -Force -ErrorAction SilentlyContinue
        if(-not (Get-ChildItem -LiteralPath $legacy -Force|Select-Object -First 1)){Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue}
        }
        PWrite "$p`n"
        }finally{if($t){Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue}}
        """#

    /// 檔案上傳到使用者選的資料夾(行為規格 F13):檔名不可為空、`.`、`..`,不可含 `/` 或 `\`(64);資料夾打不開 66。
    /// gzip 傳輸：傳輸 bytes 先寫進第二個暫存檔(不放記憶體),大小要等於傳輸大小，再以 `GZipStream` 解壓，
    /// 解壓後要等於原始大小，否則 75。參數：資料夾、檔名、原始大小、傳輸編碼(`identity`／`gzip`)、傳輸大小。
    static let folderUpload = #"""
        $n=$a[1];$z=[long]$a[2];$transferSize=[long]$a[4]
        \#(uploadLimit(transferSizeArgument: 4))
        if(-not $n -or $n -eq '.' -or $n -eq '..' -or $n.Contains('/') -or $n.Contains('\')){exit 64}
        if(-not [IO.Directory]::Exists($a[0])){[Console]::Error.Write("cannot open $($a[0])");exit 66}
        $d=(Get-Item -LiteralPath $a[0] -Force).FullName
        $t=Join-Path $d ('.purrdr-upload.'+[Guid]::NewGuid().ToString('N'));$purrdrLimit.Files+=$t
        $gz=$null;$transfer=$null
        $p=Join-Path $d $n
        try{
        try{$w=[IO.File]::Open($t,'CreateNew','Write','Delete')}catch{exit 71}
        try{
        if($a[3] -ceq 'gzip'){
        $gz="$t.gz";$purrdrLimit.Files+=$gz;try{$transfer=[IO.File]::Open($gz,'CreateNew','ReadWrite','Delete')}catch{exit 71}
        try{PReceive $transfer $transferSize}catch{exit 72}
        if($transfer.Length -ne $transferSize){exit 75}
        $transfer.Position=0;try{(New-Object IO.Compression.GZipStream($transfer,[IO.Compression.CompressionMode]::Decompress)).CopyTo($w)}catch{exit 75}
        }else{try{PReceive $w $transferSize}catch{exit 72}}
        }finally{$w.Close();if($transfer){$transfer.Close()}}
        if((New-Object IO.FileInfo $t).Length -ne $z){exit 75}
        if(Test-Path -LiteralPath $p){exit 73}
        try{[IO.File]::Move($t,$p)}catch{if(Test-Path -LiteralPath $p){exit 73};exit 71}
        $t=$null
        PWrite "$p`n"
        }finally{foreach($f in @($t,$gz)){if($f){Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue}}}
        """#

    /// 一次性腳本的自我時限(#92),`seconds` 秒後結束。背景 runspace 到 `$purrdrLimit.At` 就刪掉登記在
    /// `$purrdrLimit.Files` 的暫存檔(開檔要允許 `Delete` 共用)、以 124 結束整個 PowerShell;主執行緒卡在讀 stdin 也有效。
    static func limit(seconds: Int) -> String {
        limit(secondsExpression: String(seconds))
    }

    /// 上傳腳本的自我時限：隨 `$a[transferSizeArgument]`(傳輸大小)加長，同 `HostScriptTimeLimit.posixUpload`。
    static func uploadLimit(transferSizeArgument index: Int) -> String {
        limit(secondsExpression: "\(HostScriptTimeLimit.readSeconds)+[long]$a[\(index)]/\(HostScriptTimeLimit.uploadBytesPerSecond)")
    }

    private static func limit(secondsExpression: String) -> String {
        "$purrdrSeconds=\(secondsExpression);" + limitWatcher
    }

    /// 時限的監看 runspace(`$purrdrSeconds` 已設好)。
    static let limitWatcher = "$purrdrLimit=[hashtable]::Synchronized(@{At=[DateTime]::UtcNow.AddSeconds($purrdrSeconds);Files=@()});$purrdrState=[Management.Automation.Runspaces.InitialSessionState]::Create();$purrdrState.LanguageMode='FullLanguage';$purrdrSpace=[runspacefactory]::CreateRunspace($purrdrState);$purrdrSpace.Open();$purrdrSpace.SessionStateProxy.SetVariable('limit',$purrdrLimit);$purrdrWatch=[PowerShell]::Create();$purrdrWatch.Runspace=$purrdrSpace;[void]$purrdrWatch.AddScript('while([DateTime]::UtcNow -lt $limit.At){[Threading.Thread]::Sleep(200)};foreach($file in $limit.Files){try{[IO.File]::Delete($file)}catch{}};[Environment]::Exit(\(HostScriptTimeLimit.exitCode))').BeginInvoke()"

    /// 把 stdin 開成 `$stdin`:以 console stream 的原始 handle 建 `FileStream`(經 sshd 時直接讀 console stream,
    /// 超過約 128 KiB 就永遠不返回，#77);取不到 handle 時退回 console stream。上傳與 `WindowsCommand.stdinStub` 共用。
    static let openStdin = "$stdin=[Console]::OpenStandardInput();try{$stdin=New-Object IO.FileStream($stdin.GetType().GetField('_handle',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($stdin),[IO.FileAccess]::Read,1,$false)}catch{}"

    /// 從 stdin 讀**剛好**宣告的大小(或讀到 EOF 為止)寫進檔案。不等 EOF:經 Git Bash 時 EOF 可能傳不到
    /// (`WindowsCommand.stdinStub`);連線中斷時讀到的會比宣告的少，由大小檢查擋下(75)。
    static let receive = #"""
        function PReceive($w,[long]$z){\#(openStdin);$c=New-Object byte[] 65536;$n=[long]0;while($n -lt $z){$r=$stdin.Read($c,0,[int][Math]::Min([long]$c.Length,$z-$n));if($r -le 0){break};$w.Write($c,0,$r);$n+=$r}}
        """#

    static func upload(_ body: String, arguments values: [String]) -> String {
        [prelude, arguments(values), receive, body].joined(separator: "\n")
    }

    // MARK: - 資料夾

    /// 資料夾清單：第一行是絕對路徑，接著每個項目一行，格式同 `ls -lnA`(種類、連結數、uid、gid、大小、月 日 時:分或年、名稱),
    /// 讓 `FolderListing.parse` 不分主機。打不開 → 66。參數：路徑(空 = 家目錄)。
    static let folderList = #"""
        $d=$a[0];if(-not $d){$d=$env:USERPROFILE}
        if(-not [IO.Directory]::Exists($d)){[Console]::Error.Write("cannot open $d");exit 66}
        try{$e=@(Get-ChildItem -LiteralPath $d -Force)}catch{[Console]::Error.Write("cannot open $d");exit 66}
        PWrite "$((Get-Item -LiteralPath $d -Force).FullName)`n"
        $v=[Globalization.CultureInfo]::InvariantCulture;$now=Get-Date
        foreach($x in $e){
        if($x.Attributes -band [IO.FileAttributes]::ReparsePoint){$k='l---------';$z=0}elseif($x.PSIsContainer){$k='d---------';$z=0}else{$k='----------';$z=$x.Length}
        $t=$x.LastWriteTime;if($t.Year -eq $now.Year -and $t -le $now.AddDays(1)){$w=$t.ToString('MMM d HH:mm',$v)}else{$w=$t.ToString('MMM d yyyy',$v)}
        PWrite "$k 1 0 0 $z $w $($x.Name)`n"
        }
        """#

    /// 新增對話的資料夾瀏覽：第一行是絕對路徑，之後每行一個子資料夾(不含 `.` 開頭與隱藏的)。`~`、`~/…`、`~\…` 是家目錄。
    /// 不存在 → 66。參數：路徑。
    static let newChatFolders = #"""
        $d=$a[0]
        if(-not $d -or $d -eq '~'){$d=$env:USERPROFILE}elseif($d.StartsWith('~/') -or $d.StartsWith('~\')){$d=Join-Path $env:USERPROFILE $d.Substring(2)}
        if(-not [IO.Directory]::Exists($d)){exit 66}
        try{$e=@(Get-ChildItem -LiteralPath $d -Directory)}catch{exit 66}
        PWrite "$((Get-Item -LiteralPath $d -Force).FullName)`n"
        foreach($x in $e){if(-not $x.Name.StartsWith('.')){PWrite "$($x.Name)`n"}}
        """#

    static func folders(_ body: String, arguments values: [String]) -> String {
        [prelude, arguments(values), body].joined(separator: "\n")
    }

    // MARK: - 主機檔案(主題、You should know、Claude 方案用量、推播配對;#68)

    /// 與 `HostFileScript` 相同的輸出格式與 exit code。家目錄是 `%USERPROFILE%`,相對路徑的 `/` 換成 `\`。
    ///
    /// - 版本是「內容的 SHA-256:大小」(POSIX 版是 `cksum`):只在同一台主機上比對讀取前後，格式不必相同。
    /// - 跟隨 symlink(`PResolve`,最多 40 層;PowerShell 5.1 的 `Item.Target`)。
    /// - 寫入：同資料夾的暫存檔，覆寫既有檔案用 `File.Replace`(保留原檔的 ACL 與屬性),新檔用 `File.Move`。
    /// - `rmtree` 用 `Directory.Delete(…, true)`:不跟進 junction／symlink 刪到外面(PowerShell 5.1 的
    ///   `Remove-Item -Recurse` 會)。
    /// - 可執行旗標在 Windows 沒有意義，忽略。
    static let hostFileFunctions = #"""
        function PPath([string]$r){Join-Path $env:USERPROFILE $r.Replace('/','\')}
        function PResolve([string]$p){$n=0;while($n -lt 40){$i=Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue;if(-not $i -or -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $i.Target){break};$t=@($i.Target)[0];if(-not [IO.Path]::IsPathRooted($t)){$t=Join-Path ([IO.Path]::GetDirectoryName($p)) $t};$p=$t;$n++};$p}
        function PHashOf([byte[]]$b){(-join ([Security.Cryptography.SHA256]::Create().ComputeHash($b)|%{$_.ToString('x2')}))+':'+$b.Length}
        function PBytes([string]$p){$h=POpen $p;try{$b=PRead $h 0 $h.Length}finally{$h.Close()};,$b}
        function PExit([string]$s,[int]$c){PWrite $s;$o.Flush();exit $c}
        function PAbort($e,[int]$c){[Console]::Error.Write("$($e.Exception.Message)");$o.Flush();exit $c}
        """#

    static func hostFiles(_ body: String, arguments values: [String]) -> String {
        [prelude, arguments(values), transcriptFunctions, hostFileFunctions, body].joined(separator: "\n")
    }

    /// `HostFileScript.read`:輸出多一行 `home <家目錄>`(`/` 分隔),讓 client 知道是 Windows 與家目錄在哪。
    static let hostFileRead = hostFileReadPrelude + #"""
        for($i=0;$i -lt $a.Count;$i++){PReadOne $a[$i] $i '-'}
        $o.Flush()
        """#

    /// `HostFileScript.readIfChanged`:參數每兩個一組(路徑、已知版本;沒有是 `-`),版本相同只印 `unchanged <i>`。
    static let hostFileReadIfChanged = hostFileReadPrelude + #"""
        for($i=0;$i+1 -lt $a.Count;$i+=2){PReadOne $a[$i] ($i/2) $a[$i+1]}
        $o.Flush()
        """#

    /// 長駐的條件式讀取(#203,輸出同 `HostFileScript.followScript`):stub 讀完腳本後，從同一個 reader(`$s`,原始 handle,#77)
    /// 繼續讀請求行「路徑 已知版本 …」,每則回應以 `end` 結束。每個請求把時限延到閒置秒數後(不超過總長)。
    /// 參數(`$a`):閒置秒數、總長秒數。
    static let hostFileFollow = hostFileReadFunctions + #"""
        $purrdrEnd=[DateTime]::UtcNow.AddSeconds([int]$a[1])
        function PIdle{$idleUntil=[DateTime]::UtcNow.AddSeconds([int]$a[0]);if($idleUntil -gt $purrdrEnd){$idleUntil=$purrdrEnd};$purrdrLimit.At=$idleUntil}
        PIdle
        while(($request=$s.ReadLine()) -ne $null){
        PIdle
        $fields=@($request.Split([char]' ',[StringSplitOptions]::RemoveEmptyEntries))
        PHeader
        for($i=0;$i+1 -lt $fields.Count;$i+=2){try{PReadOne $fields[$i] ($i/2) $fields[$i+1]}catch{PWrite "unreadable $($i/2)`n"}}
        PWrite "end`n"
        $o.Flush()
        }
        $o.Flush()
        exit 0
        """#

    /// 讀取共用：開頭三行，與讀一個檔案的 `PReadOne <路徑> <序號> <已知版本>`。
    private static let hostFileReadPrelude = hostFileReadFunctions + #"""
        PHeader

        """#

    /// 讀取的共用函式：開頭三行 `PHeader` 與 `PReadOne`。
    private static let hostFileReadFunctions = #"""
        function PHeader{PWrite "purrdr-files 1`nuser $env:USERNAME`nhome $($env:USERPROFILE.Replace('\','/'))`n"}
        function PReadOne([string]$r,[int]$i,[string]$k){
        $p=PResolve (PPath $r)
        if([IO.File]::Exists($p)){
        try{$h=POpen $p}catch{PWrite "unreadable $i`n";return}
        if($h.Length -gt 1048576){$h.Close();PWrite "toolarge $i`n";return}
        try{$b=PRead $h 0 $h.Length}catch{$h.Close();PWrite "unreadable $i`n";return};$h.Close()
        $v=PHashOf $b
        if($v -ceq $k){PWrite "unchanged $i`n";return}
        PWrite "file $i $v $($b.Length)`n";$o.Write($b,0,$b.Length);PWrite "`n"
        }elseif([IO.Directory]::Exists($p)){PWrite "other $i`n"}
        elseif([IO.Directory]::Exists([IO.Path]::GetDirectoryName($p))){PWrite "missing $i`n"}
        else{PWrite "nodir $i`n"}
        }

        """#

    /// `HostFileScript.apply`:先檢查全部(不符 → `changed <路徑>` exit 3;資料夾不存在 → `nodir <路徑>` exit 4),
    /// 全部符合才依序寫。
    static let hostFileApply = #"""
        $made=@()
        for($i=0;$i+4 -lt $a.Count;$i+=5){
        $k=$a[$i];$r=$a[$i+1];$e=$a[$i+2]
        if($k -ceq 'rmtree' -or $k -ceq 'rmdir'){continue}
        $q=PPath $r
        if($k -ceq 'mkdir'){if(Get-Item -LiteralPath $q -Force -ErrorAction SilentlyContinue){PExit "changed $r`n" 3};$made+=$q;continue}
        $p=PResolve $q
        if($e -ceq 'missing'){if(Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue){PExit "changed $r`n" 3}}
        elseif($e -cne 'any'){if(-not [IO.File]::Exists($p)){PExit "changed $r`n" 3};try{$b=PBytes $p}catch{PExit "changed $r`n" 3};if((PHashOf $b) -cne $e){PExit "changed $r`n" 3}}
        if($k -ceq 'put' -and -not $r.StartsWith('.purrdr/')){$d=[IO.Path]::GetDirectoryName($p);if(-not [IO.Directory]::Exists($d) -and -not ($made -contains $d)){PExit "nodir $r`n" 4}}
        }
        for($i=0;$i+4 -lt $a.Count;$i+=5){
        $k=$a[$i];$r=$a[$i+1];$x=$a[$i+3];$q=PPath $r
        switch -CaseSensitive($k){
        'put'{
        $p=PResolve $q;$d=[IO.Path]::GetDirectoryName($p)
        try{[void][IO.Directory]::CreateDirectory($d)}catch{PAbort $_ 71}
        try{$b=[Convert]::FromBase64String($x)}catch{PAbort $_ 72}
        $t=Join-Path $d ('.purrdr-tmp.'+[Guid]::NewGuid().ToString('N'))
        try{[IO.File]::WriteAllBytes($t,$b);if([IO.File]::Exists($p)){[void][IO.File]::Replace($t,$p,[NullString]::Value)}else{[IO.File]::Move($t,$p)}}catch{$f=$_;if([IO.File]::Exists($t)){[IO.File]::Delete($t)};PAbort $f 71}
        }
        'del'{$p=PResolve $q;try{if([IO.File]::Exists($p)){[IO.File]::Delete($p)}}catch{PAbort $_ 71}}
        'rmtree'{
        if(-not $r.StartsWith('.purrdr/') -or $r.Length -le 8){exit 64}
        try{if([IO.Directory]::Exists($q)){[IO.Directory]::Delete($q,$true)}}catch{PAbort $_ 71}
        $w=PPath '.purrdr';try{if([IO.Directory]::Exists($w) -and @([IO.Directory]::GetFileSystemEntries($w)).Count -eq 0){[IO.Directory]::Delete($w)}}catch{}
        }
        'mkdir'{try{[void][IO.Directory]::CreateDirectory($q)}catch{PAbort $_ 71}}
        'rmdir'{try{if([IO.Directory]::Exists($q) -and @([IO.Directory]::GetFileSystemEntries($q)).Count -eq 0){[IO.Directory]::Delete($q)}}catch{}}
        }
        }
        $o.Flush()
        """#

    /// `HostFileScript.newest`:資料夾裡檔名開頭、結尾符合、最新(修改時間)的可讀一般檔案。參數：資料夾、開頭、結尾。
    static let hostFileNewest = #"""
        $d=PPath $a[0];$n=$null;$m=$null
        if([IO.Directory]::Exists($d)){foreach($e in @(Get-ChildItem -LiteralPath $d -Force -File)){$x=$e.Name
        if($x.Length -ge $a[1].Length+$a[2].Length -and $x.StartsWith($a[1],[StringComparison]::Ordinal) -and $x.EndsWith($a[2],[StringComparison]::Ordinal)){
        try{$h=POpen $e.FullName;$h.Close()}catch{continue}
        if($m -eq $null -or $e.LastWriteTimeUtc -gt $m){$m=$e.LastWriteTimeUtc;$n=$x}}}}
        PWrite "purrdr-newest 1`n"
        if($n){PWrite "$($a[0])/$n`n"}
        $o.Flush()
        """#

    /// `SSHPushPluginInstaller.otherPairingsScript`:`~\.purrdr\push-*\pairing`,每行 `push-<id>/pairing`。
    static let pushPairings = #"""
        $d=PPath '.purrdr'
        if([IO.Directory]::Exists($d)){foreach($e in @(Get-ChildItem -LiteralPath $d -Force -Directory|?{$_.Name -clike 'push-*'})){if([IO.File]::Exists((Join-Path $e.FullName 'pairing'))){PWrite "$($e.Name)/pairing`n"}}}
        $o.Flush()
        """#

    /// `SSHPushTestNotifier.script`:同樣的檢查、輸出與 exit code(66 沒有配對、70 連不上)。參數：配對資料夾名稱。純 ASCII。
    static let pushTest = #"""
        $f=PPath ('.purrdr/'+$a[0]+'/pairing')
        if(-not [IO.File]::Exists($f)){exit 66}
        $k=$null;$e=$null
        foreach($l in [IO.File]::ReadAllLines($f)){if($l.StartsWith('key=')){$k=$l.Substring(4)}elseif($l.StartsWith('endpoint=')){$e=$l.Substring(9)}}
        if(-not $k -or $k -cnotmatch '^[0-9a-f]{64}$' -or -not $e){exit 66}
        $n='';if($a.Count -gt 1 -and $a[1]){$n=',"host_name":"'+$a[1]+'"'}
        $c=0
        try{$r=Invoke-WebRequest -UseBasicParsing -Uri $e -Method Post -ContentType 'application/json' -Body ('{"key":"'+$k+'","event":"test"'+$n+'}') -TimeoutSec 10;$c=[int]$r.StatusCode}
        catch{if($_.Exception.Response){$c=[int]$_.Exception.Response.StatusCode}else{[Console]::Error.Write($_.Exception.Message);exit 70}}
        if($c -eq 410){$cur=$null;foreach($l in [IO.File]::ReadAllLines($f)){if($l.StartsWith('key=')){$cur=$l.Substring(4)}};if($cur -ceq $k){Remove-Item -LiteralPath ([IO.Path]::GetDirectoryName($f)) -Recurse -Force -ErrorAction SilentlyContinue}}
        PWrite "$c`\n"
        $o.Flush()
        """#

    // MARK: - 變更頁的唯讀 git(#310)

    /// `GitChangesCommand.script` 的 PowerShell 版:同樣的參數(`status 工作目錄` 或 `diff 工作目錄 標記 單檔上限 總量上限 (種類 路徑)…`)、
    /// 輸出格式與 exit code(64 用法、65 不是 repo、66 資料夾不存在、69 沒有 git)。唯讀:`GIT_OPTIONAL_LOCKS=0`、diff 不跑外部程式。
    /// git 以 Process 啟動、直接讀 stdout 的 bytes(經 console 轉碼會把非 ASCII 路徑弄壞)。純 ASCII。
    static let gitChanges = #"""
        $g=Get-Command git -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if(-not $g){exit 69}
        $env:GIT_OPTIONAL_LOCKS='0';$env:GIT_TERMINAL_PROMPT='0';$env:LC_ALL='C'
        function PGit([string[]]$x,[long]$max,[string]$dir){
        $p=New-Object Diagnostics.ProcessStartInfo
        $p.FileName=$g.Source;$p.WorkingDirectory=$dir;$p.UseShellExecute=$false;$p.RedirectStandardOutput=$true;$p.RedirectStandardError=$true;$p.CreateNoWindow=$true
        $p.Arguments=(($x|%{'"'+(($_ -replace '(\\+)$','$1$1') -replace '"','\"')+'"'}) -join ' ')
        $r=[Diagnostics.Process]::Start($p)
        $e=$r.StandardError.ReadToEndAsync()
        $m=New-Object IO.MemoryStream;$c=New-Object byte[] 65536
        while($true){$n=$r.StandardOutput.BaseStream.Read($c,0,$c.Length);if($n -le 0){break}
        if($max -ge 0 -and $m.Length+$n -gt $max){$m.Write($c,0,[int]($max-$m.Length));try{$r.Kill()}catch{};break}
        $m.Write($c,0,$n)}
        $r.WaitForExit()
        [pscustomobject]@{Out=$m.ToArray();Code=$r.ExitCode}}
        if($a.Count -lt 2 -or ($a[0] -cne 'status' -and $a[0] -cne 'diff')){exit 64}
        if(-not [IO.Directory]::Exists($a[1])){exit 66}
        $t=PGit @('rev-parse','--show-toplevel') -1 $a[1]
        if($t.Code -ne 0){exit 65}
        $root=$u.GetString($t.Out).Trim("`r","`n")
        if($a[0] -ceq 'status'){
        $b=PGit @('symbolic-ref','--short','-q','HEAD') -1 $root
        $branch=$u.GetString($b.Out).Trim("`r","`n")
        PWrite "branch $branch`nroot $root`n"
        $s=PGit @('-c','core.quotepath=off','status','--porcelain=v1','-z','--untracked-files=all','--no-renames','--ignore-submodules=all') -1 $root
        $o.Write($s.Out,0,$s.Out.Length)}
        else{
        $file=[long]$a[3];$total=[long]$a[4]
        $base='HEAD';if((PGit @('rev-parse','-q','--verify','HEAD') -1 $root).Code -ne 0){$base='4b825dc642cb6eb9a060e54bf8d69288fbee4904'}
        $all=New-Object IO.MemoryStream;$i=0
        for($k=5;$k+1 -lt $a.Count -and $all.Length -le $total;$k+=2){
        $h=$u.GetBytes("`n$($a[2]) $i`n");$all.Write($h,0,$h.Length)
        if($a[$k] -ceq 'untracked'){$d=PGit @('diff','--no-index','--no-color','--no-ext-diff','--no-textconv','-U3','--','/dev/null',$a[$k+1]) ($file+1) $root}
        else{$d=PGit @('diff','--no-color','--no-ext-diff','--no-textconv','-U3',$base,'--',$a[$k+1]) ($file+1) $root}
        $all.Write($d.Out,0,$d.Out.Length);$i++}
        $z=$all.ToArray();$n=[Math]::Min([long]$z.Length,$total+1);$o.Write($z,0,[int]$n)}
        $o.Flush()
        """#

    // MARK: - 主機取檔(#226)

    /// `HostFileFetchScript.follow` 的 PowerShell 版，協定相同。參數(`$a`):閒置、總長秒數、大小上限。
    static func hostFileFetch(arguments values: [String]) -> String {
        [prelude, arguments(values), fetchSettings, transcriptFunctions, hostFileFunctions, hostFileFetchScript].joined(separator: "\n")
    }

    /// 排除清單的 `-like` 樣式(路徑轉成小寫、`/` 分隔後比對)與一次讀取的上限。
    static var fetchSettings: String {
        let patterns = HostFileAccessPolicy.excludedLocations.flatMap { location in
            ["*/\(location.lowercased())", "*/\(location.lowercased())/*"]
        }
        return "$purrdrExcluded=@(" + patterns.map(PowerShell.quote).joined(separator: ",") + ");$purrdrChunk=\(HostFileFetchScript.maximumChunk)"
    }

    /// 存取規則與 POSIX 版、主機服務相同(共用案例 `vendor/purrdr-host/protocol/host-file-access.json`):工作目錄不能是磁碟機根目錄、
    /// `%USERPROFILE%` 或它的上層;沒有工作目錄(`-`,`HostFileFetchScript.noWorkingDirectory`)時只放行 `%TEMP%`、
    /// 家目錄的 `AppData\Local\Temp`、`.purrdr\uploads` 與 Claude 的 `tool-results`;`-uploads`(只因使用者 prompt 提到)只放行上傳資料夾
    /// (`%TEMP%` 或家目錄 `AppData\Local\Temp` 的直接子資料夾 `purrdr-uploads`,或 `.purrdr\uploads`)。先比對請求的路徑，再以
    /// `GetFinalPathNameByHandle` 取得 junction／symlink／8.3 短檔名都解析後的實際路徑比對;讀取用的 handle 也再核對一次。
    /// 只收磁碟機路徑,ADS、UNC 拒絕。版本是「SHA-256:大小」;從頭讀時把內容留在記憶體當快照，之後的分塊都從快照切。
    static let hostFileFetchScript = #"""
        Add-Type -TypeDefinition @'
        using System;
        using System.Runtime.InteropServices;
        using System.Text;
        using Microsoft.Win32.SafeHandles;
        public static class PurrdrFinalPath {
          const uint NoAccess = 0;
          const uint ShareReadWriteDelete = 7;
          const uint OpenExisting = 3;
          const uint BackupSemantics = 0x02000000;
          public const int AccessDenied = 5;
          [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
          static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
          [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
          static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint size, uint flags);
          public static int LastError;
          public static string OfHandle(SafeFileHandle handle) {
            var buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length >= buffer.Capacity) { buffer = new StringBuilder((int)length + 1); length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0); }
            if (length == 0 || length >= buffer.Capacity) { LastError = Marshal.GetLastWin32Error(); return null; }
            var path = buffer.ToString();
            if (path.StartsWith(@"\\?\UNC\")) { return @"\\" + path.Substring(8); }
            if (path.StartsWith(@"\\?\")) { return path.Substring(4); }
            return path;
          }
          public static string Of(string path) {
            LastError = 0;
            using (var handle = CreateFileW(path, NoAccess, ShareReadWriteDelete, IntPtr.Zero, OpenExisting, BackupSemantics, IntPtr.Zero)) {
              if (handle.IsInvalid) { LastError = Marshal.GetLastWin32Error(); return null; }
              return OfHandle(handle);
            }
          }
        }
        '@
        $idleSeconds=[int]$a[0];$totalSeconds=[int]$a[1];$maximumSize=[long]$a[2];$requestReader=$s
        # 請求裡「沒有工作目錄」(只因對話紀錄提到而放行),同 HostFileFetchScript.noWorkingDirectory。
        $noRoot='-'
        # 請求裡「只因使用者 prompt 提到而放行」:只放行 Purrdr 上傳資料夾,同 HostFileFetchScript.userUploadOnly。
        $uploadsOnly='-uploads'
        $homeFinal=$null;if($env:USERPROFILE){$homeFinal=[PurrdrFinalPath]::Of($env:USERPROFILE)}
        $temporaryFinal=$null;if($env:TEMP){$temporaryFinal=[PurrdrFinalPath]::Of($env:TEMP)}
        function PDrivePath([string]$path){$path -match '^[A-Za-z]:[\\/]' -and $path.IndexOf(':',2) -lt 0}
        function PPlainPath([string]$path){(PDrivePath $path) -and -not @($path.Split([char[]]'\/') | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count}
        function PComparable([string]$path){$path.Replace('/','\').TrimEnd('\').ToLowerInvariant()}
        function PUnder([string]$path,[string]$folder){if(-not $folder){return $false};(PComparable $path).StartsWith((PComparable $folder)+'\')}
        function PExcluded([string]$path){$lowered=$path.Replace('\','/').ToLowerInvariant();foreach($pattern in $purrdrExcluded){if($lowered -like $pattern){return $true}};$false}
        function PHomeForms{@($env:USERPROFILE,$homeFinal) | Where-Object { $_ }}
        function PTooBroad([string]$folder){
        $comparableFolder=PComparable $folder
        if($comparableFolder -match '^[a-z]:$'){return $true}
        foreach($homeFolder in PHomeForms){$comparableHome=PComparable $homeFolder;if($comparableHome -eq $comparableFolder -or $comparableHome.StartsWith($comparableFolder+'\')){return $true}}
        $false
        }
        function PMentionable([string]$path){
        $locations=@($env:TEMP,$env:TMP,$temporaryFinal)
        foreach($homeFolder in PHomeForms){$locations+=(Join-Path $homeFolder 'AppData\Local\Temp');$locations+=(Join-Path $homeFolder '.purrdr\uploads')}
        foreach($location in $locations){if(PUnder $path $location){return $true}}
        foreach($homeFolder in PHomeForms){if((PComparable $path) -like ((PComparable $homeFolder)+'\.claude\projects\*\*\tool-results\*')){return $true}}
        $false
        }
        function PUploadFolderName([string]$name){$name -match '^\#(HostServiceProtocol.uploadFolder)(-unknown|-\d+)?$'}
        function PDirectUpload([string]$path,[string]$temporary){
        if(-not $temporary){return $false}
        $comparable=PComparable $path;$base=(PComparable $temporary)+'\'
        if(-not $comparable.StartsWith($base)){return $false}
        $rest=$comparable.Substring($base.Length);$slash=$rest.IndexOf('\')
        if($slash -lt 1){return $false}
        PUploadFolderName $rest.Substring(0,$slash)
        }
        function PUploadLocation([string]$path){
        $locations=@($env:TEMP,$env:TMP,$temporaryFinal)
        foreach($homeFolder in PHomeForms){$locations+=(Join-Path $homeFolder 'AppData\Local\Temp')}
        foreach($location in $locations){if(PDirectUpload $path $location){return $true}}
        foreach($homeFolder in PHomeForms){if(PUnder $path (Join-Path $homeFolder '.purrdr\uploads')){return $true}}
        $false
        }
        function PAllowed([string]$path,[string]$root){
        if(PExcluded $path){return $false}
        if($root -ceq $noRoot){return (PMentionable $path)}
        if($root -ceq $uploadsOnly){return (PUploadLocation $path)}
        if(PTooBroad $root){return $false}
        PUnder $path $root
        }
        function PLocate([string]$path,[string]$root){
        $script:fetchHandle=$null
        $rootless=($root -ceq $noRoot -or $root -ceq $uploadsOnly)
        if(-not (PPlainPath $path) -or (-not $rootless -and -not (PPlainPath $root))){return 'denied'}
        try{$path=[IO.Path]::GetFullPath($path);if(-not $rootless){$root=[IO.Path]::GetFullPath($root)}}catch{return 'denied'}
        if(-not (PAllowed $path $root)){return 'denied'}
        if($rootless){$rootFinal=$root}else{$rootFinal=[PurrdrFinalPath]::Of($root);if(-not $rootFinal){return 'missing'}}
        $final=[PurrdrFinalPath]::Of($path)
        if(-not $final){if([PurrdrFinalPath]::LastError -eq [PurrdrFinalPath]::AccessDenied){return 'unreadable'};return 'missing'}
        if(-not (PAllowed $final $rootFinal)){return 'denied'}
        if([IO.Directory]::Exists($final)){return 'other'}
        try{$handle=POpen $final}catch{return 'unreadable'}
        if([PurrdrFinalPath]::OfHandle($handle.SafeFileHandle) -cne $final){$handle.Close();return 'denied'}
        if($handle.Length -gt $maximumSize){$size=$handle.Length;$handle.Close();return "toolarge $size"}
        $script:fetchHandle=$handle;$script:fetchTarget=$final
        'file'
        }
        function PDecode([string]$encoded){try{$u.GetString([Convert]::FromBase64String($encoded))}catch{''}}
        function PRequestRoot([string]$encoded){if($encoded -ceq $noRoot -or $encoded -ceq $uploadsOnly){$encoded}else{PDecode $encoded}}
        function PStat([string]$path,[string]$root){
        $verdict=PLocate $path $root
        if($verdict -cne 'file'){PWrite "$verdict`n";return}
        $handle=$script:fetchHandle;try{$contents=PRead $handle 0 $handle.Length}catch{PWrite "unreadable`n";return}finally{$handle.Close()}
        PWrite "file $(PHashOf $contents) $($contents.Length)`n"
        }
        function PReadChunk([string]$path,[string]$root,[string]$version,[string]$offsetText,[string]$lengthText){
        $verdict=PLocate $path $root
        if($verdict -cne 'file'){PWrite "$verdict`n";return}
        $handle=$script:fetchHandle
        try{
        if($offsetText -notmatch '^\d{1,15}$' -or $lengthText -notmatch '^\d{1,15}$'){PWrite "bad`n";return}
        if([long]$offsetText -eq 0 -or $script:snapshotPath -cne $script:fetchTarget -or $script:snapshotVersion -cne $version){
        try{$contents=PRead $handle 0 $handle.Length}catch{PWrite "unreadable`n";return}
        $script:snapshot=$contents;$script:snapshotVersion=PHashOf $contents;$script:snapshotPath=$script:fetchTarget
        }
        }finally{$handle.Close()}
        if($script:snapshotVersion -cne $version){PWrite "changed`n";return}
        $total=[long]$script:snapshot.Length;$start=[long]$offsetText;$count=[Math]::Min([long]$lengthText,[long]$purrdrChunk)
        if($start -ge $total){$count=0}elseif($start+$count -gt $total){$count=$total-$start}
        $encoded=[Convert]::ToBase64String($script:snapshot,[int]$start,[int]$count)
        PWrite "chunk $start $count $($encoded.Length)`n$encoded`n"
        }
        $purrdrEnd=[DateTime]::UtcNow.AddSeconds($totalSeconds)
        function PIdle{$idleUntil=[DateTime]::UtcNow.AddSeconds($idleSeconds);if($idleUntil -gt $purrdrEnd){$idleUntil=$purrdrEnd};$purrdrLimit.At=$idleUntil}
        PIdle
        while(($request=$requestReader.ReadLine()) -ne $null){
        PIdle
        $fields=@($request.Split([char]' ',[StringSplitOptions]::RemoveEmptyEntries))
        try{
        if($fields.Count -eq 3 -and $fields[0] -ceq 'stat'){PStat (PDecode $fields[1]) (PRequestRoot $fields[2])}
        elseif($fields.Count -eq 6 -and $fields[0] -ceq 'read'){PReadChunk (PDecode $fields[1]) (PRequestRoot $fields[2]) $fields[3] $fields[4] $fields[5]}
        else{PWrite "bad`n"}
        }catch{PWrite "unreadable`n"}
        PWrite "end`n"
        $o.Flush()
        }
        $o.Flush()
        exit 0
        """#

    // MARK: - Claude Code 的 slash 清單探索(#68,`ClaudeSlashCommand`)

    /// 與 POSIX 版相同的紀錄格式(`@F`、`@S`、`@L`,內容每行前面加 `|`)。路徑以參數原樣為基準、往下一律接 `/`,
    /// 所以 `ClaudeSlashDiscovery` 的解析(`/SKILL.md` 結尾、基準資料夾 + `/`)不分主機。CRLF 的檔案照樣讀得懂。
    /// 每個函式自己吞掉錯誤(讀不到的檔就略過),與 POSIX 版一樣只要腳本跑完就是 exit 0。
    static let slashFunctions = #"""
        function PDump([string]$t,[string]$f){try{if([IO.File]::Exists($f)){$x=[IO.File]::ReadAllText($f,$u).Replace("`r`n","`n");PWrite "@F`t$t`t$f`n";if($x.EndsWith("`n")){$x=$x.Substring(0,$x.Length-1)};if($x.Length -gt 0){foreach($y in $x.Split("`n")){PWrite "|$y`n"}};PWrite "`n"}}catch{}}
        function PFront([string]$t,[string]$b,[string]$f){PWrite "@S`t$t`t$b`t$f`n";try{$l=[IO.File]::ReadAllLines($f,$u)}catch{return};if($l.Count -eq 0 -or $l[0] -cne '---'){return};for($j=1;$j -lt $l.Count;$j++){if($l[$j] -ceq '---'){break};PWrite "|$($l[$j])`n"}}
        function PSkills([string]$t,[string]$d){try{if([IO.File]::Exists("$d/SKILL.md")){PFront $t $d "$d/SKILL.md"}elseif([IO.Directory]::Exists($d)){foreach($e in @(Get-ChildItem -LiteralPath $d -Force -Directory|Sort-Object Name)){$s="$d/$($e.Name)/SKILL.md";if([IO.File]::Exists($s)){PFront $t $d $s}}}}catch{}}
        function PCommands([string]$t,[string]$d){try{if([IO.File]::Exists($d)){PFront $t $d.Substring(0,$d.LastIndexOfAny([char[]]'/\')) $d}elseif([IO.Directory]::Exists($d)){$r=(Get-Item -LiteralPath $d -Force).FullName.TrimEnd('\','/');foreach($e in @(Get-ChildItem -LiteralPath $d -Force -Recurse -File|?{$_.Name.EndsWith('.md',[StringComparison]::Ordinal)})){PFront $t $d ($d+'/'+$e.FullName.Substring($r.Length+1).Replace('\','/'))}}}catch{}}
        """#

    /// 第 1 步：參數是工作資料夾、對話紀錄路徑(沒有時空字串)。
    static let slashDiscover = slashFunctions + "\n" + #"""
        $c=PHome $env:CLAUDE_CONFIG_DIR '.claude'
        PDump 'installed' "$c/plugins/installed_plugins.json"
        PDump 'settings' "$c/settings.json"
        if($a[0]){
        PDump 'project-settings' "$($a[0])/.claude/settings.json"
        PDump 'local-settings' "$($a[0])/.claude/settings.local.json"
        PSkills 'project' "$($a[0])/.claude/skills"
        PCommands 'project' "$($a[0])/.claude/commands"
        }
        PSkills 'user' "$c/skills"
        PCommands 'user' "$c/commands"
        if($a[1] -and [IO.File]::Exists($a[1])){
        try{$s=New-Object IO.StreamReader((POpen $a[1]),$u);PWrite "@L`n";while(($l=$s.ReadLine()) -ne $null){if($l.Contains('"skill_listing"')){PWrite "|$l`n"}};$s.Close()}catch{}
        }
        $o.Flush()
        """#

    /// 第 2 步：參數是每個 plugin 的 installPath。
    static let slashManifests = slashFunctions + "\n" + #"""
        foreach($p in $a){PDump $p "$p/.claude-plugin/plugin.json"}
        $o.Flush()
        """#

    /// 第 3 步：參數每三個一組(種類 `s`／`c`、plugin 名稱、路徑)。
    static let slashScan = slashFunctions + "\n" + #"""
        for($i=0;$i+2 -lt $a.Count;$i+=3){if($a[$i] -ceq 's'){PSkills $a[$i+1] $a[$i+2]}else{PCommands $a[$i+1] $a[$i+2]}}
        $o.Flush()
        """#
}
