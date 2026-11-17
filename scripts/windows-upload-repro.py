"""Windows 主機上傳的回歸檢查(#77):經真正的 sshd 執行 app 實際送出的上傳指令。

從 `src/PurrdrCore/WindowsScripts.swift` 取出 prelude、receive 與上傳腳本，照 `WindowsScripts.upload` 組成
`powershell.exe … -EncodedCommand`,經 `ssh` 執行並把 bytes 寫進 stdin(送完送 EOF)。
期限內 exit 0、印出的路徑正確、主機檔案 SHA-256 與送出的相同為綠;逾時(卡住)或其他結果為紅。

用法:
  PURRDR_WINDOWS_HOST=user@host[:port] PURRDR_WINDOWS_KEY=<私鑰> \
    python -I scripts/windows-upload-repro.py [大小…] [--kind image|folder|both] [--timeout 秒]
  預設大小 100、300000、2500000,kind both。全部綠 exit 0。

每個案例在主機 `%TEMP%\\purrdr-repro-<亂數>` 裡進行(圖片上傳以 `$env:USERPROFILE` 指過去，檔案上傳的目的資料夾也在裡面),
結束就刪掉。逾時時只結束命令列含本案例指令的程序(含卡住的 PowerShell)。
"""
import argparse
import base64
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


def swift_literal(source, name):
    """`static let <name> = #\"\"\" … \"\"\"#` 的內容(去掉縮排，與 Swift 多行字串相同)。"""
    match = re.search(r"static let " + name + r' = #"""\n(.*?)\n( *)"""#', source, re.S)
    if not match:
        sys.exit(f"WindowsScripts.swift 找不到 {name}")
    body, indent = match.group(1), match.group(2)
    return "\n".join(line[len(indent):] if line.startswith(indent) else line for line in body.split("\n"))


def quote(text):
    """同 `PowerShell.quote`:單引號(含彎引號)重複。"""
    return "'" + "".join(c * 2 if c in "'‘’‚‛" else c for c in text) + "'"


def encoded(script):
    return LAUNCHER + base64.b64encode(script.encode("utf-16-le")).decode()


def ssh_argv(remote_command):
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
    completed = subprocess.run(ssh_argv(encoded("$ProgressPreference='SilentlyContinue';" + script)),
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


def run_case(source, kind, size, timeout, mismatch=None):
    """`mismatch`:`transfer` 或 `original` 時宣告的大小故意多 1,預期 exit 75、資料夾是空的。"""
    workspace = run_powershell(
        "$d=Join-Path $env:TEMP ('purrdr-repro-'+[Guid]::NewGuid().ToString('N'));"
        "[void][IO.Directory]::CreateDirectory((Join-Path $d 'files'));[Console]::Out.Write($d)")
    if not workspace:
        return False, "建立主機暫存資料夾失敗"
    name = uuid.uuid4().hex[:12] + (".jpg" if kind == "image" else ".bin")
    prelude, receive = swift_literal(source, "prelude"), swift_literal(source, "receive")
    payload = compressible(size) if kind == "gzip" else os.urandom(size)
    sent = payload
    if kind == "image":
        arguments = [name, str(size)]
        body = "$env:USERPROFILE=" + quote(workspace) + "\n" + swift_literal(source, "imageUpload")
        expected_path = workspace + "\\.purrdr\\uploads\\" + name
    else:
        folder = workspace + "\\files"
        if kind == "gzip":
            sent = gzip.compress(payload, mtime=0)
        original_size = size + (1 if mismatch == "original" else 0)
        transfer_size = len(sent) + (1 if mismatch == "transfer" else 0)
        arguments = [folder, name, str(original_size), "gzip" if kind == "gzip" else "identity", str(transfer_size)]
        body = swift_literal(source, "folderUpload")
        expected_path = folder + "\\" + name
    upload_command = encoded("\n".join([prelude, "$a=@(" + ",".join(quote(v) for v in arguments) + ")", receive, body]))

    started = time.monotonic()
    process = subprocess.Popen(ssh_argv(upload_command), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        stdout, stderr = process.communicate(sent, timeout=timeout)
        elapsed = time.monotonic() - started
        printed = stdout.decode("utf-8", errors="replace").strip()
        if mismatch:
            left = run_powershell("@(Get-ChildItem -LiteralPath " + quote(workspace + "\\files") + " -Force).Count")
            if process.returncode != 75 or left != "0":
                return False, f"exit={process.returncode} 資料夾剩 {left} 個項目(預期 exit 75、0 個)"
            return True, f"{elapsed:.1f}s exit 75、沒留下檔案"
        if process.returncode != 0 or printed != expected_path:
            detail = f"exit={process.returncode} {elapsed:.1f}s stdout={printed!r} stderr={stderr.decode(errors='replace')[:200]!r}"
            return False, detail
        remote_hash = run_powershell("(Get-FileHash -Algorithm SHA256 -LiteralPath " + quote(expected_path) + ").Hash")
        original_hash = hashlib.sha256(payload).hexdigest()
        if remote_hash.lower() != original_hash:
            return False, f"{elapsed:.1f}s SHA-256 不同：原檔 {original_hash} 主機 {remote_hash.lower()}"
        transfer = f"傳輸 {len(sent)} bytes " if sent is not payload else ""
        return True, f"{elapsed:.1f}s {transfer}SHA-256 相同"
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
    parser.add_argument("--kind", choices=["image", "folder", "gzip", "all"], default="all")
    parser.add_argument("--timeout", type=float, default=20)
    options = parser.parse_args()
    with open(os.path.join(REPO, "src", "PurrdrCore", "WindowsScripts.swift"), encoding="utf-8") as file:
        source = file.read()
    kinds = ["image", "folder", "gzip"] if options.kind == "all" else [options.kind]
    cases = [(kind, size, None) for kind in kinds for size in options.sizes]
    if "gzip" in kinds:
        cases += [("gzip", max(options.sizes), mismatch) for mismatch in ("transfer", "original")]
    all_green = True
    for kind, size, mismatch in cases:
        green, detail = run_case(source, kind, size, options.timeout, mismatch)
        all_green &= green
        label = kind + (f"({mismatch} 不符)" if mismatch else "")
        print(f"{'GREEN' if green else 'RED  '} {label:16} {size:>9} bytes  {detail}", flush=True)
    print("全部綠燈" if all_green else "有紅燈")
    sys.exit(0 if all_green else 1)


if __name__ == "__main__":
    main()
