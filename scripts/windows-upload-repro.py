"""Windows 主機上傳的回歸檢查(#76):經真正的 sshd 執行 app 實際送出的上傳指令與 stdin stub。

從 `src/*/` 底下的 `WindowsScripts.swift`、`WindowsHostChannel.swift`(常數另讀 `HostScriptTimeLimit.swift`、`HostServiceProtocol.swift`)取出腳本，照 `WindowsScripts.upload`
(stub 照 `WindowsCommand.viaStdin`)組成 `powershell.exe … -EncodedCommand`,經 `ssh` 執行並把 bytes 寫進 stdin。
腳本以 regex 從 Swift 原始碼抽出：抽不到或有沒展開的插值時直接結束並說明(Swift 寫法改了要同步改這裡)。
期限內 exit 0、輸出正確、主機檔案 SHA-256 與原檔相同為綠;逾時(卡住)或其他結果為紅。

kind(各跑每個大小):
  image   上傳到主機的 `%TEMP%/purrdr-uploads`(`hostUpload`,圖片與聊天附加檔案共用)
  folder  檔案上傳，identity 傳輸
  gzip    檔案上傳，gzip 傳輸;另加傳輸／原始大小不符(exit 75、不留檔)與
          「傳到一半時已收到的 bytes 已寫到磁碟」(不整個放進記憶體)
  stub    唯讀腳本的 stdin stub:送指定大小的腳本，讀到結束標記就執行
  stub-eof(隨 stub 一起跑)  stub 只收到半份腳本就 EOF:不執行，exit 74(Swift 的 `stdinTruncatedExit`)
  limit   自我時限(#92,時限換短，見 `SHORT_LIMITS`):stub 只收到一半腳本、腳本本體卡住、圖片／檔案上傳只送一半，
          都要以 exit 124 結束、程序樹不留程序、上傳不留暫存檔(需要主機預設 shell 是 Git Bash,以 `/proc/$$/winpid` 找根)
上傳與 stub 的 kind 另跑 100 bytes 的「沒有 `_handle` 欄位」模擬(換掉欄位名，應退回直接讀 console stream)。
shell:`bash` 直接執行(主機預設 shell,這台是 Git Bash);`cmd` 包成 `cmd.exe //c '<指令>'`,模擬預設 shell 是 cmd。

用法:
  PURRDR_WINDOWS_HOST=user@host[:port] PURRDR_WINDOWS_KEY=<私鑰> \
    python -I scripts/windows-upload-repro.py [大小…] [--kind image|folder|gzip|stub|limit|all] [--shell bash|cmd|all] [--timeout 秒]
  預設大小 100、300000、2500000,kind all,shell all。全部綠 exit 0。

每個案例在主機 `%TEMP%\\purrdr-repro-<亂數>` 裡進行(hostUpload 以 `$env:USERPROFILE` 與 `$env:TEMP` 指過去，檔案上傳的目的資料夾也在裡面),
結束就刪掉。逾時時只結束開著本案例暫存檔的程序(卡住的 PowerShell)。
"""
import argparse
import base64
import glob
import gzip
import hashlib
import os
import re
import subprocess
import sys
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCHER = "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "
# PURRDR_WINDOWS_LOCAL=1:不經 sshd,直接在本機啟動 powershell.exe(CI 的 Windows runner 用;啟動參數與 app 相同)。
LOCAL = os.environ.get("PURRDR_WINDOWS_LOCAL") == "1"


SWIFT_FILES = ("WindowsScripts.swift", "WindowsHostChannel.swift", "HostScriptTimeLimit.swift", "HostServiceProtocol.swift")


def swift_source():
    """`SWIFT_FILES` 的內容(在 `src/` 底下哪個 target 都可以;找不到或不只一份就結束)。"""
    source = ""
    for file_name in SWIFT_FILES:
        found = glob.glob(os.path.join(REPO, "src", "*", file_name))
        if len(found) != 1:
            sys.exit(f"src/*/{file_name} 找到 {len(found)} 份(要剛好一份):檔案搬家或改名了，請更新 SWIFT_FILES")
        with open(found[0], encoding="utf-8") as file:
            source += file.read()
    return source


# 內容由 `TranscriptLocator.all` 產生的腳本:不在這裡重算,直接讀 golden 檔(`TranscriptScriptGoldenTests` 保證與 app 產生的一致)。
GOLDEN_FOLDER = os.path.join(REPO, "tests", "PurrdrTestSupport", "Fixtures", "golden-scripts")
GOLDEN_LITERALS = {"transcriptFunctions": "windows.transcriptFunctions.ps1", "previews": "windows.previews.ps1"}


def swift_literal(source, name):
    """`static let <name> = #\"\"\" … \"\"\"#` 的內容(去掉縮排，與 Swift 多行字串相同);由定位規則產生的兩份腳本改讀 golden 檔。"""
    if name in GOLDEN_LITERALS:
        with open(os.path.join(GOLDEN_FOLDER, GOLDEN_LITERALS[name]), encoding="utf-8", newline="") as golden:
            return golden.read()
    match = re.search(r"static let " + name + r' = #"""\n(.*?)\n( *)"""#', source, re.S)
    if not match:
        sys.exit(f"Swift 原始碼找不到 `static let {name} = #\"\"\"…\"\"\"#`:寫法改了，請更新本腳本的抽取方式")
    body, indent = match.group(1), match.group(2)
    return "\n".join(line[len(indent):] if line.startswith(indent) else line for line in body.split("\n"))


INTERPOLATION = r"\\#?\((?:\w+\.)?(\w+)\)"
# `WindowsScripts.limit(seconds: X)` 與 `uploadLimit(transferSizeArgument: N)`:照 Swift 的組法展開。
LIMIT = r"\\#?\((?:WindowsScripts\.)?limit\(seconds: (?:\w+\.)?(\w+)\)\)"
UPLOAD_LIMIT = r"\\#?\((?:WindowsScripts\.)?uploadLimit\(transferSizeArgument: (\d+)\)\)"


def swift_string(source, name, overrides=None):
    """`static let <name> = "…"`(一行、除了插值不含跳脫字元的一般字串)或整數常數;`overrides` 換掉常數值。"""
    if overrides and name in overrides:
        return overrides[name]
    match = re.search(r'static let ' + name + r' = "((?:[^"\\]|' + INTERPOLATION + r')*)"', source)
    if match:
        return resolve(match.group(1), source, overrides)
    match = re.search(r"static let " + name + r" = ([0-9_]+)\n", source)
    if not match:
        sys.exit(f"Swift 原始碼找不到常數 {name}(一行字串或整數):寫法改了，請更新本腳本的抽取方式")
    return match.group(1).replace("_", "")


def limit_script(seconds, source, overrides=None):
    """同 `WindowsScripts.limit(secondsExpression:)`:`$purrdrSeconds=<秒數算式>;` 加上監看 runspace。"""
    return "$purrdrSeconds=" + seconds + ";" + swift_string(source, "limitWatcher", overrides)


def resolve(text, source, overrides=None):
    """展開 `\\(X)`、`\\#(X)` 字串插值(X 是 `source` 裡的一行字串常數或整數常數)與時限的函式呼叫。
    展開後仍有插值就結束：不把沒展開的 Swift 語法當成 PowerShell 送出去。"""
    def constant(name):
        return swift_string(source, name, overrides)

    text = re.sub(LIMIT, lambda match: limit_script(constant(match.group(1)), source, overrides), text)
    text = re.sub(UPLOAD_LIMIT, lambda match: limit_script(
        constant("readSeconds") + "+[long]$a[" + match.group(1) + "]/" + constant("uploadBytesPerSecond"), source, overrides), text)
    text = re.sub(INTERPOLATION, lambda match: constant(match.group(1)), text)
    leftover = re.search(r"\\#?\([^)]*\)?", text)
    if leftover:
        sys.exit(f"有展開不了的 Swift 插值 {leftover.group(0)!r}:寫法改了，請更新本腳本的 resolve")
    return text


def stdin_stub(source, overrides=None):
    """`WindowsCommand.stdinStub` 的腳本(插值已展開)。"""
    match = re.search(r'static let stdinStub = PowerShell\.encodedCommand\(\s*"(.*?)"\)\n', source, re.S)
    if not match:
        sys.exit("Swift 原始碼找不到 `static let stdinStub = PowerShell.encodedCommand(\"…\")`:寫法改了，請更新本腳本")
    return resolve(match.group(1), source, overrides)


def quote(text):
    """同 `PowerShell.quote`:單引號(含彎引號)重複。"""
    return "'" + "".join(c * 2 if c in "'‘’‚‛" else c for c in text) + "'"


def encoded(script):
    return LAUNCHER + base64.b64encode(script.encode("utf-16-le")).decode()


def posix_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def local_argv(script):
    """本機直接啟動的命令列:同 `LAUNCHER`,腳本以 -EncodedCommand 傳入。"""
    return LAUNCHER.split() + [base64.b64encode(script.encode("utf-16-le")).decode()]


def ssh_argv(remote_command, shell="bash"):
    if shell == "cmd":
        remote_command = "cmd.exe //c " + posix_quote(remote_command)
    target = os.environ.get("PURRDR_WINDOWS_HOST") or sys.exit("要設定 PURRDR_WINDOWS_HOST=user@host[:port]")
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    if os.environ.get("PURRDR_WINDOWS_KEY"):
        argv += ["-i", os.path.expanduser(os.environ["PURRDR_WINDOWS_KEY"])]
    host, _, port = target.rpartition(":") if re.search(r":\d+$", target) else (target, "", "")
    if port:
        argv += ["-p", port]
    return argv + [host, remote_command]


def run_powershell(script, timeout=60):
    """在主機執行一段輔助 PowerShell,回傳 stdout(去頭尾空白)。"""
    script = "$ProgressPreference='SilentlyContinue';" + script
    completed = subprocess.run(local_argv(script) if LOCAL else ssh_argv(encoded(script)),
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    return completed.stdout.decode("utf-8", errors="replace").strip()


# Restart Manager 查出鎖住檔案的程序。經 sshd 啟動的程序讀不到命令列，只能從它開著的暫存檔反查。
LOCKERS = r"""
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class PurrdrReproLockers {
  [StructLayout(LayoutKind.Sequential)] struct Unique { public int Pid; public long Started; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Info {
    public Unique Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string App;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Service;
    public int Type; public int Status; public int Session; [MarshalAs(UnmanagedType.Bool)] public bool Restartable; }
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint handle, int flags, StringBuilder key);
  [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint handle);
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint handle, uint fileCount, string[] files, uint appCount, IntPtr apps, uint serviceCount, string[] services);
  [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint handle, out uint needed, ref uint count, [In, Out] Info[] infos, ref uint reasons);
  public static int[] Of(string[] files) {
    uint handle; RmStartSession(out handle, 0, new StringBuilder(64));
    try {
      RmRegisterResources(handle, (uint)files.Length, files, 0, IntPtr.Zero, 0, null);
      uint needed, count = 0, reasons = 0;
      RmGetList(handle, out needed, ref count, null, ref reasons);
      if (needed == 0) { return new int[0]; }
      var infos = new Info[needed]; count = needed;
      RmGetList(handle, out needed, ref count, infos, ref reasons);
      var pids = new int[count];
      for (int i = 0; i < count; i++) { pids[i] = infos[i].Process.Pid; }
      return pids;
    } finally { RmEndSession(handle); }
  }
}
'@
"""


def stop_stuck_processes(workspace):
    """只結束開著本案例暫存資料夾裡檔案的程序(卡住的 PowerShell)。"""
    return run_powershell(
        LOCKERS + "$f=@(Get-ChildItem -LiteralPath " + quote(workspace) + " -Recurse -Force -File|%{$_.FullName})\n"
        "if($f.Count){[PurrdrReproLockers]::Of($f)|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue;$_}}")


def compressible(size):
    """像 log 的文字(gzip 壓得小)。"""
    lines, total = [], 0
    while total < size:
        line = f"{total:09d} {os.urandom(6).hex()} purrdr upload log line\n".encode()
        lines.append(line)
        total += len(line)
    return b"".join(lines)[:size]


STUB_OK = "purrdr-stub-ok"
MISSING_FIELD = "'_purrdrNoSuchField'"


def stub_script(size):
    """印出 `STUB_OK` 的腳本，以註解行補到約 `size` bytes。"""
    lines, total = ["[Console]::Out.Write('" + STUB_OK + "')"], 0
    while total < size:
        lines.append("# " + "x" * 98)
        total += 101
    return "\n".join(lines)


def on_disk_bytes(folder):
    """資料夾裡所有檔案(含開著的暫存檔)的大小總和。
    目錄列舉的大小要等檔案關閉才更新，所以逐檔以 `FileInfo` 重查。"""
    total = run_powershell("(@(Get-ChildItem -LiteralPath " + quote(folder) + " -Force -File|%{(New-Object IO.FileInfo $_.FullName).Length})"
                           "|Measure-Object -Sum).Sum")
    return int(total) if total.isdigit() else 0


def upload_script(source, kind, arguments, workspace, overrides=None):
    """照 `WindowsScripts.upload` 組成上傳腳本;hostUpload 以 `$env:USERPROFILE`、`$env:TEMP` 指到 `workspace`。"""
    prelude = swift_literal(source, "prelude")
    receive = resolve(swift_literal(source, "receive"), source, overrides)
    if kind == "image":
        body = "$env:USERPROFILE=" + quote(workspace) + "\n$env:TEMP=" + quote(workspace) + "\n" + resolve(swift_literal(source, "hostUpload"), source, overrides)
    else:
        body = resolve(swift_literal(source, "folderUpload"), source, overrides)
    # `$a` 是 `WindowsScripts.arguments` 的參數陣列，所有 Windows 腳本共用;上傳腳本在 cmd 命令列(8,191 字元)裡，名稱維持短。
    return "\n".join([prelude, "$a=@(" + ",".join(quote(v) for v in arguments) + ")", receive, body])


# 程序樹：從根(Windows pid)往下找子孫，子程序的建立時間不早於父程序(避開重複使用的 pid)。
TREE = r"""
$processes=@(Get-CimInstance Win32_Process);$found=@{};$root=@($processes|Where-Object{$_.ProcessId -eq ROOT});if($root.Count){$found[[int]ROOT]=$root[0]}
$queue=New-Object Collections.Queue;$queue.Enqueue([int]ROOT)
while($queue.Count){$current=$queue.Dequeue();foreach($process in $processes){$id=[int]$process.ProcessId;if($process.ParentProcessId -eq $current -and $id -ne $current -and -not $found.ContainsKey($id) -and (-not $found[$current] -or $process.CreationDate -ge $found[$current].CreationDate)){$found[$id]=$process;$queue.Enqueue($id)}}}
$found.Values|ForEach-Object{"$($_.ProcessId) $($_.Name) $($_.CreationDate.ToFileTimeUtc())"}
"""


def host_tree(root):
    """主機上 `root` 與它所有子孫：[(pid, 名稱, 建立時間)]。"""
    lines = run_powershell(TREE.replace("ROOT", str(int(root)))).splitlines()
    return [tuple(line.split(" ")) for line in lines if line.count(" ") == 2]


def still_running(processes):
    """`processes` 裡還在的(pid 與建立時間都相同)。"""
    if not processes:
        return []
    wanted = ",".join(f"'{pid} {created}'" for pid, _, created in processes)
    alive = run_powershell("$w=@(" + wanted + ");Get-CimInstance Win32_Process|?{$w -contains \"$($_.ProcessId) $($_.CreationDate.ToFileTimeUtc())\"}"
                           "|%{$_.ProcessId}").split()
    return [process for process in processes if process[0] in alive]


def stop_processes(processes):
    """只結束 `processes` 裡還在的程序(以 pid 與建立時間確認是同一個)。"""
    for pid, _, _ in still_running(processes):
        run_powershell(f"Stop-Process -Id {int(pid)} -Force -ErrorAction SilentlyContinue")


# 自我時限的案例把時限換短(秒;上傳的速度換大，時限就只剩固定的部分)。
SHORT_LIMITS = {"stdinScriptSeconds": "4", "readSeconds": "6", "uploadBytesPerSecond": "1000000000"}
LIMIT_CASES = {
    "stub-partial": "stdin stub 只收到一半腳本(沒有結束標記)",
    "stub-stuck": "stdin stub 收到完整腳本，腳本本體卡住",
    "image-stall": "上傳到主機(hostUpload)只送一半 bytes",
    "folder-stall": "檔案上傳只送一半 bytes",
}


def run_limit_case(source, case, timeout, shell):
    """卡住的 Windows 腳本要在時限內以 exit 124 結束，程序樹(以 Git Bash 的 `/proc/$$/winpid` 為根)不留下任何程序;
    上傳另檢查暫存檔已刪掉。stdin 一直開著(不送 EOF),模擬 app 斷線但 channel 沒關。"""
    workspace = run_powershell(
        "$d=Join-Path $env:TEMP ('purrdr-repro-'+[Guid]::NewGuid().ToString('N'));"
        "[void][IO.Directory]::CreateDirectory((Join-Path $d 'files'));[Console]::Out.Write($d)")
    if not workspace:
        return False, "建立主機暫存資料夾失敗"
    end_marker = swift_string(source, "endOfScript")
    limit = int(SHORT_LIMITS["readSeconds"])
    if case in ("stub-partial", "stub-stuck"):
        command_script = stdin_stub(source, SHORT_LIMITS)
        if case == "stub-partial":
            feed = stub_script(1000).encode()[:500]
            limit = int(SHORT_LIMITS["stdinScriptSeconds"])
        else:
            feed = ("[Threading.Thread]::Sleep(-1)\n" + end_marker + "\n").encode()
            limit += int(SHORT_LIMITS["stdinScriptSeconds"])
        check_folder = None
    else:
        size = 300_000
        name = uuid.uuid4().hex[:12] + (".jpg" if case == "image-stall" else ".bin")
        if case == "image-stall":
            arguments = [name, str(size)]
            check_folder = workspace + "\\purrdr-uploads"
        else:
            check_folder = workspace + "\\files"
            arguments = [check_folder, name, str(size), "identity", str(size)]
        command_script = upload_script(source, case.split("-")[0], arguments, workspace, SHORT_LIMITS)
        feed = os.urandom(size // 2)
    remote = "cat /proc/$$/winpid >&2; " + (encoded(command_script) if shell == "bash" else "cmd.exe //c " + posix_quote(encoded(command_script)))
    started = time.monotonic()
    process = subprocess.Popen(ssh_argv(remote), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    processes = []
    try:
        root = process.stderr.readline().decode().strip()
        if not root.isdigit():
            return False, f"拿不到主機程序的 winpid({root!r});預設 shell 要是 Git Bash"
        process.stdin.write(feed)
        process.stdin.flush()
        time.sleep(1.5)
        processes = host_tree(root)
        if not any(name.lower() == "powershell.exe" for _, name, _ in processes):
            return False, f"程序樹裡沒有 powershell.exe:{processes}"
        deadline = started + limit + timeout
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.2)
        elapsed = time.monotonic() - started
        if process.poll() is None:
            return False, f"{elapsed:.1f}s 還沒結束(時限 {limit}s)"
        processes = processes + [p for p in host_tree(root) if p not in processes]
        time.sleep(0.5)
        left = still_running(processes)
        if left:
            return False, f"{elapsed:.1f}s exit={process.returncode},主機還留著 {left}"
        if process.returncode != 124:
            return False, f"{elapsed:.1f}s exit={process.returncode}(預期 124)"
        files = run_powershell("@(Get-ChildItem -LiteralPath " + quote(check_folder) + " -Force -ErrorAction SilentlyContinue).Count") if check_folder else "0"
        if files not in ("", "0"):
            return False, f"{elapsed:.1f}s exit 124,但上傳資料夾留下 {files} 個暫存檔"
        return True, f"{elapsed:.1f}s exit 124(時限 {limit}s),程序樹 {len(processes)} 個程序都已結束"
    finally:
        if process.poll() is None:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)] if os.name == "nt" else ["kill", str(process.pid)],
                           capture_output=True)
        process.communicate()
        stop_processes(processes)
        run_powershell("Remove-Item -LiteralPath " + quote(workspace) + " -Recurse -Force -ErrorAction SilentlyContinue")


def run_stub_eof_case(source, timeout, shell):
    """stub 只收到半份腳本(沒有結束標記)就遇到 EOF(傳輸被截斷):不執行已讀到的內容，exit `stdinTruncatedExit`。"""
    truncated_exit = int(swift_string(source, "stdinTruncatedExit"))
    command_script = stdin_stub(source)
    truncated = ("[Console]::Out.Write('first-half-ran')\n").encode()
    started = time.monotonic()
    process = subprocess.Popen(ssh_argv(encoded(command_script), shell), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        stdout, _ = process.communicate(truncated, timeout=timeout)
    except subprocess.TimeoutExpired:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)] if os.name == "nt" else ["kill", str(process.pid)],
                       capture_output=True)
        process.communicate()
        return False, f"逾時 {timeout}s:EOF 後 stub 還沒結束"
    elapsed = time.monotonic() - started
    printed = stdout.decode("utf-8", errors="replace").strip()
    if printed or process.returncode != truncated_exit:
        return False, f"exit={process.returncode} {elapsed:.1f}s stdout={printed!r}(預期 exit {truncated_exit}、stdout 空)"
    return True, f"{elapsed:.1f}s exit {truncated_exit},沒有執行已讀到的內容"


def run_case(source, kind, size, timeout, shell, variant=None):
    """`variant`:
    - `transfer`／`original`:宣告的大小故意多 1,預期 exit 75、資料夾是空的。
    - `spool`:先送一半，等已收到的 bytes 出現在磁碟上，再送完。
    - `no-handle`:console stream 沒有 `_handle` 欄位(換掉欄位名),預期照常完成。
    """
    workspace = run_powershell(
        "$d=Join-Path $env:TEMP ('purrdr-repro-'+[Guid]::NewGuid().ToString('N'));"
        "[void][IO.Directory]::CreateDirectory((Join-Path $d 'files'));[Console]::Out.Write($d)")
    if not workspace:
        return False, "建立主機暫存資料夾失敗"
    name = uuid.uuid4().hex[:12] + (".jpg" if kind == "image" else ".bin")
    payload = compressible(size) if kind == "gzip" else os.urandom(size)
    sent = payload
    folder = workspace + "\\files"
    if kind == "stub":
        command_script = stdin_stub(source)
        sent = (stub_script(size) + "\n" + swift_string(source, "endOfScript") + "\n").encode()
        expected_output = STUB_OK
    else:
        if kind == "image":
            arguments = [name, str(size)]
            expected_output = workspace + "\\purrdr-uploads\\" + name
        else:
            if kind == "gzip":
                sent = gzip.compress(payload, mtime=0)
            original_size = size + (1 if variant == "original" else 0)
            transfer_size = len(sent) + (1 if variant == "transfer" else 0)
            arguments = [folder, name, str(original_size), "gzip" if kind == "gzip" else "identity", str(transfer_size)]
            expected_output = folder + "\\" + name
        command_script = upload_script(source, kind, arguments, workspace)
    if variant == "no-handle":
        if "'_handle'" not in command_script:
            return False, "腳本裡沒有 '_handle',模擬不成立"
        command_script = command_script.replace("'_handle'", MISSING_FIELD)

    started = time.monotonic()
    process = subprocess.Popen(ssh_argv(encoded(command_script), shell), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        spooled = None
        if variant == "spool":
            half = len(sent) // 2
            process.stdin.write(sent[:half])
            process.stdin.flush()
            deadline = time.monotonic() + 8
            spooled = on_disk_bytes(folder)
            while spooled == 0 and time.monotonic() < deadline:
                time.sleep(0.5)
                spooled = on_disk_bytes(folder)
            sent_rest = sent[half:]
        else:
            sent_rest = sent
        stdout, stderr = process.communicate(sent_rest, timeout=timeout)
        elapsed = time.monotonic() - started
        printed = stdout.decode("utf-8", errors="replace").strip()
        if variant in ("transfer", "original"):
            left = run_powershell("@(Get-ChildItem -LiteralPath " + quote(folder) + " -Force).Count")
            if process.returncode != 75 or left != "0":
                return False, f"exit={process.returncode} 資料夾剩 {left} 個項目(預期 exit 75、0 個)"
            return True, f"{elapsed:.1f}s exit 75、沒留下檔案"
        if process.returncode != 0 or printed != expected_output:
            detail = f"exit={process.returncode} {elapsed:.1f}s stdout={printed!r} stderr={stderr.decode(errors='replace')[:300]!r}"
            return False, detail
        if spooled == 0:
            return False, f"送出一半({len(sent) // 2} bytes)後磁碟上仍是 0 bytes:傳輸整個放在記憶體"
        spool_note = f"送一半時磁碟上 {spooled} bytes " if spooled else ""
        if kind == "stub":
            return True, f"{elapsed:.1f}s 腳本 {len(sent)} bytes 已執行"
        remote_hash = run_powershell("(Get-FileHash -Algorithm SHA256 -LiteralPath " + quote(expected_output) + ").Hash")
        original_hash = hashlib.sha256(payload).hexdigest()
        if remote_hash.lower() != original_hash:
            return False, f"{elapsed:.1f}s SHA-256 不同：原檔 {original_hash} 主機 {remote_hash.lower()}"
        transfer = f"傳輸 {len(sent)} bytes " if sent is not payload else ""
        return True, f"{elapsed:.1f}s {transfer}{spool_note}SHA-256 相同"
    except subprocess.TimeoutExpired:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)] if os.name == "nt" else ["kill", str(process.pid)],
                       capture_output=True)
        process.communicate()
        stopped = stop_stuck_processes(workspace).split()
        return False, f"逾時 {timeout}s(卡住);已結束主機程序 {stopped}"
    finally:
        run_powershell("Remove-Item -LiteralPath " + quote(workspace) + " -Recurse -Force -ErrorAction SilentlyContinue")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sizes", nargs="*", type=int, default=[100, 300_000, 2_500_000])
    parser.add_argument("--kind", choices=["image", "folder", "gzip", "stub", "limit", "all"], default="all")
    parser.add_argument("--shell", choices=["bash", "cmd", "all"], default="all")
    parser.add_argument("--timeout", type=float, default=20)
    options = parser.parse_args()
    source = swift_source()
    kinds = ["image", "folder", "gzip", "stub", "limit"] if options.kind == "all" else [options.kind]
    shells = ["bash", "cmd"] if options.shell == "all" else [options.shell]
    upload_kinds = [kind for kind in kinds if kind != "limit"]
    cases = [(kind, size, None) for kind in upload_kinds for size in options.sizes]
    if "gzip" in kinds:
        cases += [("gzip", max(options.sizes), variant) for variant in ("transfer", "original", "spool")]
    cases += [(kind, 100, "no-handle") for kind in upload_kinds]
    all_green = True
    for shell in shells:
        for kind, size, variant in cases:
            green, detail = run_case(source, kind, size, options.timeout, shell, variant)
            all_green &= green
            label = f"{shell} {kind}" + (f"({variant})" if variant else "")
            print(f"{'GREEN' if green else 'RED  '} {label:24} {size:>9} bytes  {detail}", flush=True)
        if "stub" in kinds:
            green, detail = run_stub_eof_case(source, options.timeout, shell)
            all_green &= green
            print(f"{'GREEN' if green else 'RED  '} {shell + ' stub-eof':24} stdin stub 截斷後 EOF  {detail}", flush=True)
        if "limit" in kinds:
            for case in LIMIT_CASES:
                green, detail = run_limit_case(source, case, options.timeout, shell)
                all_green &= green
                print(f"{'GREEN' if green else 'RED  '} {shell + ' ' + case:24} {LIMIT_CASES[case]}  {detail}", flush=True)
    print("全部綠燈" if all_green else "有紅燈")
    sys.exit(0 if all_green else 1)


if __name__ == "__main__":
    main()
