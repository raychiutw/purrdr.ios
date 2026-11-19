"""Windows 主機檔案長駐讀取(#203)經真正 sshd 的回歸檢查與流量量測。

腳本從 Swift 原始碼抽出(共用 `windows-upload-repro.py` 的抽取函式):stub 照 `WindowsCommand.viaStdin`,長駐讀取照
`WindowsScripts.hostFiles(WindowsScripts.hostFileFollow, …)`,對照組(一次性條件式讀取)照 `hostFileReadIfChanged`。
stdin 送完腳本與結束標記後不送 EOF,接著一行一個請求「路徑 已知版本 …」,回應以 `end` 行結束(內容照宣告長度跳過)。
家目錄 `%USERPROFILE%` 在腳本開頭指到暫存資料夾，不讀寫真正的家目錄。

kind:
  cases    同一條通道：第一次讀、沒變 unchanged、內容含 end 行的新內容、檔案不在、資料夾不在;stub 與腳本只送一次
  limit    閒置時限(3 秒)以 exit 124 結束、程序樹不留程序
  measure  以 `ssh -v` 的「Transferred」量 SSH 層位元組:一次性讀取(每次一條連線，扣掉只跑 `exit` 的連線)與
           長駐通道每輪(11 輪減 1 輪再除以 10),各量檔案沒變與有變

用法(要在 Windows 主機本機跑：測試檔寫在本機 %TEMP%):
  PURRDR_WINDOWS_HOST=user@127.0.0.1 PURRDR_WINDOWS_KEY=<私鑰> \
    python -I scripts/windows-host-files-repro.py [--kind cases|limit|measure|all]
全部綠 exit 0。只結束本次啟動的程序樹裡的程序(以 pid 與建立時間確認)。
"""
import argparse
import importlib.util
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("upload_repro", os.path.join(HERE, "windows-upload-repro.py"))
repro = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(repro)

REPLY_TIMEOUT = 20
THEME = ".config/herdr/config.toml"


def composed_literal(source, name, base):
    """`static let <name> = <base> + #\"\"\" … \"\"\"#` 的內容(去掉縮排)。"""
    match = re.search(r"static let " + name + r" = " + base + r' \+ #"""\n(.*?)\n( *)"""#', source, re.S)
    if not match:
        sys.exit(f"Swift 原始碼找不到 `static let {name} = {base} + #\"\"\"…\"\"\"#`:寫法改了，請更新本腳本")
    body, indent = match.group(1), match.group(2)
    return "\n".join(line[len(indent):] if line.startswith(indent) else line for line in body.split("\n"))


def script_stdin(source, home, arguments, body):
    """stdin 的腳本部分(同 `WindowsScripts.hostFiles`):家目錄指到 `home`,接著結束標記。"""
    script = "\n".join([
        repro.swift_literal(source, "prelude"),
        "$env:USERPROFILE=" + repro.quote(home),
        "$a=@(" + ",".join(repro.quote(str(v)) for v in arguments) + ")",
        repro.swift_literal(source, "transcriptFunctions"),
        repro.swift_literal(source, "hostFileFunctions"),
        repro.swift_literal(source, "hostFileReadFunctions"),
        body,
    ])
    return (script + "\n" + repro.swift_string(source, "endOfScript") + "\n").encode()


def follow_stdin(source, home, idle=60, total=600):
    return script_stdin(source, home, [idle, total], composed_literal(source, "hostFileFollow", "hostFileReadFunctions"))


def one_shot_stdin(source, home, path, known):
    body = "PHeader\n" + composed_literal(source, "hostFileReadIfChanged", "hostFileReadPrelude")
    return script_stdin(source, home, [path, known], body)


def transferred(stderr):
    """`ssh -v` 結束時的「Transferred: sent N, received M bytes」。"""
    match = re.search(rb"Transferred: sent (\d+), received (\d+) bytes", stderr)
    if not match:
        raise RuntimeError("ssh -v 沒有印出 Transferred:" + stderr[-300:].decode(errors="replace"))
    return int(match.group(1)), int(match.group(2))


class Reader:
    """一條長駐讀取通道(一個 ssh 程序)。"""

    def __init__(self, source, home, idle=60, total=600, verbose=False):
        remote = "cat /proc/$$/winpid >&2; " + repro.encoded(repro.stdin_stub(source))
        argv = repro.ssh_argv(remote)
        if verbose:
            argv.insert(1, "-v")
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.root = self.process.stderr.readline().decode().strip()
        self.stderr = b""
        self.chunks = queue.Queue()
        self.buffer = b""
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        self.process.stdin.write(follow_stdin(source, home, idle, total))
        self.process.stdin.flush()

    def _read(self):
        while True:
            chunk = self.process.stdout.read1(65536)
            if not chunk:
                break
            self.chunks.put(chunk)
        self.chunks.put(None)

    def _read_stderr(self):
        self.stderr += self.process.stderr.read()

    def take_reply(self):
        """同 `HostFileScript.takeFollowReply`:回傳 `end` 之前的部分，還不完整是 None。"""
        offset = 0
        while True:
            newline = self.buffer.find(b"\n", offset)
            if newline < 0:
                return None
            line = self.buffer[offset:newline]
            if line == b"end":
                reply, self.buffer = self.buffer[:offset], self.buffer[newline + 1:]
                return reply
            fields = line.split(b" ")
            if fields[0] == b"file":
                size = int(fields[3])
                if len(self.buffer) - (newline + 1) < size + 1:
                    return None
                offset = newline + 1 + size + 1
            else:
                offset = newline + 1

    def read(self, pairs, timeout=REPLY_TIMEOUT):
        self.process.stdin.write((" ".join(f"{path} {known}" for path, known in pairs) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while (reply := self.take_reply()) is None:
            chunk = self.chunks.get(timeout=max(0.1, deadline - time.monotonic()))
            if chunk is None:
                raise EOFError(f"通道結束 exit={self.process.wait()}")
            self.buffer += chunk
        return reply

    def tree(self):
        return repro.host_tree(self.root) if self.root.isdigit() else []

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=20)
        time.sleep(0.2)
        return self.stderr


def version_of(reply, index=0):
    match = re.search(rb"^file " + str(index).encode() + rb" (\S+) ", reply, re.M)
    return match.group(1).decode() if match else "-"


def write(home, relative, data):
    path = os.path.join(home, *relative.split("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as file:
        file.write(data)


def run_cases(source):
    home = tempfile.mkdtemp(prefix="purrdr-hostfiles-")
    write(home, THEME, b'[theme]\nname = "dracula"\n')
    reader = Reader(source, home)
    trees = []
    try:
        first = reader.read([(THEME, "-")])
        trees = reader.tree()
        version = version_of(first)
        unchanged = reader.read([(THEME, version)])
        write(home, THEME, b'[theme]\nname = "nord"\nend\n')
        changed = reader.read([(THEME, version)])
        missing = reader.read([(".purrdr/claude-usage/usage.json", "-"), (".claude/nope.json", "-")])
        checks = {
            "第一次回內容": first.endswith(b'file 0 ' + version.encode() + b' 25\n[theme]\nname = "dracula"\n\n') and b"\nhome " in first,
            "沒變 unchanged": unchanged.endswith(b"unchanged 0\n"),
            "內容含 end 行": changed.endswith(b'[theme]\nname = "nord"\nend\n\n'),
            "不在／資料夾不在": missing.endswith(b"nodir 0\nnodir 1\n"),
        }
        green = all(checks.values())
        return green, " · ".join(f"{name} {'OK' if ok else 'NG'}" for name, ok in checks.items())
    finally:
        reader.close()
        repro.stop_processes(repro.still_running(trees))
        shutil.rmtree(home, ignore_errors=True)


def run_limit(source):
    home = tempfile.mkdtemp(prefix="purrdr-hostfiles-")
    reader = Reader(source, home, idle=3, total=60)
    trees = []
    try:
        reader.read([(THEME, "-")])
        started = time.monotonic()
        trees = reader.tree()
        reader.process.wait(timeout=20)
        elapsed = time.monotonic() - started
        time.sleep(1)
        left = repro.still_running(trees)
        repro.stop_processes(left)
        green = reader.process.returncode == 124 and 2 <= elapsed <= 8 and not left
        return green, f"閒置 3s:{elapsed:.1f}s exit={reader.process.returncode},程序樹 {len(trees)} 個、留下 {len(left)} 個"
    finally:
        if reader.process.poll() is None:
            reader.process.kill()
        repro.stop_processes(repro.still_running(trees))
        shutil.rmtree(home, ignore_errors=True)


def one_connection(argv_tail, stdin_bytes):
    argv = repro.ssh_argv(argv_tail)
    argv.insert(1, "-v")
    completed = subprocess.run(argv, input=stdin_bytes, capture_output=True, timeout=60)
    return transferred(completed.stderr), completed.stdout


def run_measure(source, samples=3):
    home = tempfile.mkdtemp(prefix="purrdr-hostfiles-")
    content = b'[theme]\nname = "dracula"\n'
    write(home, THEME, content)
    stub = repro.encoded(repro.stdin_stub(source))
    results = []
    try:
        def total(pair):
            return pair[0] + pair[1]

        baseline = min(total(one_connection("exit", b"")[0]) for _ in range(samples))
        _, first = one_connection(stub, one_shot_stdin(source, home, THEME, "-"))
        version = version_of(first)
        one_shot_unchanged = min(total(one_connection(stub, one_shot_stdin(source, home, THEME, version))[0]) for _ in range(samples))
        one_shot_changed = min(total(one_connection(stub, one_shot_stdin(source, home, THEME, "stale:1"))[0]) for _ in range(samples))
        results.append(f"一次性讀取：沒變 {one_shot_unchanged - baseline} B、有變 {one_shot_changed - baseline} B(扣掉只跑 exit 的連線 {baseline} B)")

        def rounds(count, changes):
            reader = Reader(source, home, verbose=True)
            known = version
            for index in range(count):
                if changes:
                    write(home, THEME, content.replace(b"dracula", f"theme{index:04d}".encode()[:7]))
                reply = reader.read([(THEME, known)])
                known = version_of(reply) if changes else known
            return total(transferred(reader.close()))

        for label, changes in (("沒變", False), ("有變", True)):
            one = min(rounds(1, changes) for _ in range(samples))
            eleven = min(rounds(11, changes) for _ in range(samples))
            results.append(f"長駐每輪{label} {(eleven - one) / 10:.0f} B(開通道含腳本 {one - baseline} B)")
        return True, ";".join(results)
    finally:
        write(home, THEME, content)
        shutil.rmtree(home, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--kind", choices=["cases", "limit", "measure", "all"], default="all")
    options = parser.parse_args()
    if os.name != "nt":
        sys.exit("要在 Windows 主機本機跑(測試檔直接寫在本機 %TEMP%)")
    source = repro.swift_source()
    all_green = True
    kinds = ["cases", "limit", "measure"] if options.kind == "all" else [options.kind]
    for kind in kinds:
        green, detail = {"cases": run_cases, "limit": run_limit, "measure": run_measure}[kind](source)
        all_green &= green
        print(f"{'GREEN' if green else 'RED  '} {kind:8} {detail}", flush=True)
    print("全部綠燈" if all_green else "有紅燈")
    sys.exit(0 if all_green else 1)


if __name__ == "__main__":
    main()
