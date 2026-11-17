import Foundation

/// Windows 主機的 PowerShell 腳本(行為規格 §11.2):與 POSIX 版本(`TranscriptCommand`、`ImageUploadCommand`、
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
    /// - `PFail`:丟出帶 exit code 的錯誤，由呼叫處決定要結束還是略過(列表預覽一個失敗不影響其他)。
    static let transcriptFunctions = #"""
        function PStrip([string]$s){$s=[regex]::Replace($s,'"[A-Za-z0-9+/=]{128,}"','""');[regex]::Replace($s,'"data:[^"]*;base64,[^"]*"','""')}
        function PLines([byte[]]$b,[int]$i,[int]$t){while($i -lt $t){$j=[Array]::IndexOf($b,[byte]10,$i,$t-$i);if($j -lt 0){break};PWrite ("$($j-$i)`t"+(PStrip $u.GetString($b,$i,$j-$i))+"`n");$i=$j+1}}
        function POpen([string]$f){[IO.File]::Open($f,'Open','Read','ReadWrite,Delete')}
        function PRead($h,[long]$s,[long]$n){$b=New-Object byte[] $n;[void]$h.Seek($s,'Begin');$t=0;while($t -lt $n){$r=$h.Read($b,$t,$n-$t);if($r -le 0){break};$t+=$r};if($t -lt $n){$c=New-Object byte[] $t;[Array]::Copy($b,$c,$t);$b=$c};,$b}
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

    /// 視窗：以 `end` 為終點往前取恰好 `lines` 行完整的行(演算法與 POSIX 版相同)。參數：路徑、終點、行數、區塊大小。
    static let window = #"""
        PRunBlock {
        $f=$a[0];$e=[long]$a[1];$n=[int]$a[2];$c=[long]$a[3]
        try{$h=POpen $f}catch{PFail 5}
        while($true){
        $s=[Math]::Max([long]0,$e-$c);$st=New-Object Collections.Generic.List[long];$z=[long]0
        if($e -gt $s){$b=PRead $h $s ($e-$s);$q=0;$known=($s -eq 0);$i=0;while($i -lt $b.Length){$j=[Array]::IndexOf($b,[byte]10,$i);if($j -lt 0){break};if($known){$st.Add($q)};$known=$true;$z=$j+1;$q=$j+1;$i=$j+1}}
        if($st.Count -lt $n -and $s -gt 0){$c=$c*4;continue}
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

    /// 列表預覽：每個請求「標記 key」,再印剝除圖片後的檔尾 48,000 bytes;Pi／OMP、Codex 先印「標記! key」與前兩行。
    /// 每個請求各自 try:一個檔不在或有歧義不影響其他。參數：標記，接著每個請求四個(key、種類、id 或路徑、資料夾名)。
    static let previews = #"""
        $m=$a[0]
        for($r=1;$r+3 -lt $a.Count;$r+=4){
        $y=$a[$r];$t=$a[$r+1]
        PWrite "$m $y`n"
        try{
        $f=PFind $t $a[$r+2] $a[$r+3]
        $h=POpen $f
        if('pi','pipath','codex' -ccontains $t){PWrite "$m! $y`n";$x=PHead2 $f;PWrite ((($u.GetString($x) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n$m $y`n"}
        $s=[Math]::Max([long]0,$h.Length-48000);$b=PRead $h $s ($h.Length-$s);$h.Close()
        PWrite ((($u.GetString($b) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n"
        }catch{}
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

    /// 圖片上傳到 `%USERPROFILE%\.purrdr\uploads`:與 POSIX 版相同的檢查與 exit code(64 檔名、71 建立失敗、72 讀 stdin、
    /// 73 已存在、75 大小不符)。先寫隱藏的暫存檔，大小相同才改名(改名不覆寫);刪掉 7 天前的檔案。參數：檔名、大小。
    /// 上傳資料夾在使用者設定檔資料夾底下，繼承它的 ACL(只有本人、SYSTEM 與 Administrators)。
    static let imageUpload = #"""
        $n=$a[0];$z=[long]$a[1]
        if($n -cnotmatch '^[A-Za-z0-9-][A-Za-z0-9.-]*$'){exit 64}
        $d=Join-Path $env:USERPROFILE '.purrdr\uploads'
        try{[void][IO.Directory]::CreateDirectory($d)}catch{exit 71}
        $t=Join-Path $d ('.upload.'+[Guid]::NewGuid().ToString('N'))
        $p=Join-Path $d $n
        try{
        try{$w=[IO.File]::Open($t,'CreateNew','Write','None')}catch{exit 71}
        try{PReceive $w $z}catch{exit 72}finally{$w.Close()}
        if((New-Object IO.FileInfo $t).Length -ne $z){exit 75}
        if(Test-Path -LiteralPath $p){exit 73}
        try{[IO.File]::Move($t,$p)}catch{if(Test-Path -LiteralPath $p){exit 73};exit 71}
        $t=$null
        $old=(Get-Date).AddDays(-7);Get-ChildItem -LiteralPath $d -Force -File|?{$_.LastWriteTime -lt $old}|Remove-Item -Force -ErrorAction SilentlyContinue
        PWrite "$p`n"
        }finally{if($t){Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue}}
        """#

    /// 檔案上傳到使用者選的資料夾(行為規格 F13):檔名不可為空、`.`、`..`,不可含 `/` 或 `\`(64);資料夾打不開 66。
    /// gzip 傳輸：收到的傳輸 bytes 要等於傳輸大小，以 `GZipStream` 解壓後要等於原始大小，否則 75。
    /// 參數：資料夾、檔名、原始大小、傳輸編碼(`identity`／`gzip`)、傳輸大小。
    static let folderUpload = #"""
        $n=$a[1];$z=[long]$a[2];$y=[long]$a[4]
        if(-not $n -or $n -eq '.' -or $n -eq '..' -or $n.Contains('/') -or $n.Contains('\')){exit 64}
        if(-not [IO.Directory]::Exists($a[0])){[Console]::Error.Write("cannot open $($a[0])");exit 66}
        $d=(Get-Item -LiteralPath $a[0] -Force).FullName
        $t=Join-Path $d ('.purrdr-upload.'+[Guid]::NewGuid().ToString('N'))
        $p=Join-Path $d $n
        try{
        try{$w=[IO.File]::Open($t,'CreateNew','Write','None')}catch{exit 71}
        try{if($a[3] -ceq 'gzip'){$m=New-Object IO.MemoryStream;try{PReceive $m $y}catch{exit 72};if($m.Length -ne $y){exit 75};$m.Position=0;try{(New-Object IO.Compression.GZipStream($m,[IO.Compression.CompressionMode]::Decompress)).CopyTo($w)}catch{exit 75}}else{try{PReceive $w $y}catch{exit 72}}}finally{$w.Close()}
        if((New-Object IO.FileInfo $t).Length -ne $z){exit 75}
        if(Test-Path -LiteralPath $p){exit 73}
        try{[IO.File]::Move($t,$p)}catch{if(Test-Path -LiteralPath $p){exit 73};exit 71}
        $t=$null
        PWrite "$p`n"
        }finally{if($t){Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue}}
        """#

    /// 從 stdin 讀**剛好**宣告的大小(或讀到 EOF 為止)寫進檔案。不等 EOF:經 Git Bash 時 EOF 可能傳不到
    /// (`WindowsCommand.stdinStub`);連線中斷時讀到的會比宣告的少，由大小檢查擋下(75)。
    /// 以 console stream 的原始 handle 建 `FileStream` 讀：經 sshd 時直接讀 console stream,超過約 128 KiB 就永遠不返回(#77)。
    static let receive = #"""
        function PReceive($w,[long]$z){$q=[Console]::OpenStandardInput();$i=New-Object IO.FileStream($q.GetType().GetField('_handle',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($q),[IO.FileAccess]::Read,1,$false);$c=New-Object byte[] 65536;$n=[long]0;while($n -lt $z){$r=$i.Read($c,0,[int][Math]::Min([long]$c.Length,$z-$n));if($r -le 0){break};$w.Write($c,0,$r);$n+=$r}}
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

    // MARK: - 主機檔案(主題、You should know、Claude 用量、推播配對;#68)

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
    static let hostFileRead = #"""
        PWrite "purrdr-files 1`nuser $env:USERNAME`nhome $($env:USERPROFILE.Replace('\','/'))`n"
        for($i=0;$i -lt $a.Count;$i++){
        $p=PResolve (PPath $a[$i])
        if([IO.File]::Exists($p)){
        try{$h=POpen $p}catch{PWrite "unreadable $i`n";continue}
        if($h.Length -gt 1048576){$h.Close();PWrite "toolarge $i`n";continue}
        try{$b=PRead $h 0 $h.Length}catch{$h.Close();PWrite "unreadable $i`n";continue};$h.Close()
        PWrite "file $i $(PHashOf $b) $($b.Length)`n";$o.Write($b,0,$b.Length);PWrite "`n"
        }elseif([IO.Directory]::Exists($p)){PWrite "other $i`n"}
        elseif([IO.Directory]::Exists([IO.Path]::GetDirectoryName($p))){PWrite "missing $i`n"}
        else{PWrite "nodir $i`n"}
        }
        $o.Flush()
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

    /// `PushHost.otherPairingsScript`:`~\.purrdr\push-*\pairing`,每行 `push-<id>/pairing`。
    static let pushPairings = #"""
        $d=PPath '.purrdr'
        if([IO.Directory]::Exists($d)){foreach($e in @(Get-ChildItem -LiteralPath $d -Force -Directory|?{$_.Name -clike 'push-*'})){if([IO.File]::Exists((Join-Path $e.FullName 'pairing'))){PWrite "$($e.Name)/pairing`n"}}}
        $o.Flush()
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
