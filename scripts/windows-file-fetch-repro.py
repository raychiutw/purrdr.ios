"""Windows 主機取檔(#226)經真正 sshd 的回歸檢查：二進位完整傳輸、存取規則、快照、時限。

腳本從 Swift 原始碼抽出(共用 `windows-upload-repro.py` 的抽取函式):stub 照 `WindowsCommand.viaStdin`,取檔腳本照
`WindowsScripts.hostFileFetch`(prelude、參數、`fetchSettings`、transcriptFunctions、hostFileFunctions、hostFileFetchScript)。
stdin 送完腳本與結束標記後不送 EOF,接著一行一個請求(`stat`／`read`,路徑 base64),回應以 `end` 結束(同 `HostFileFetchScript`)。
測試檔只建在本機 %TEMP% 的自建資料夾，測完整個刪掉。

kind:
  binary  PNG、JPEG、PDF、含 NUL 與所有高位元組的二進位、上限前 1 byte 的大檔：以 192 KiB 分塊讀完，SHA-256 與原檔比對;
          印出每輪(一個 chunk 請求)stdout 的位元組，大檔另以 `ssh -v` 量 SSH 層總位元組;上限 +1 byte 回 toolarge
  access  存取規則：工作目錄大小寫不同、磁碟機代號小寫、`/` 分隔都允許;junction 跳出工作目錄、junction 指到排除清單、
          symbolic link 跳出工作目錄(建不了就略過)、排除清單大小寫不同、別的磁碟機、相對路徑、ADS、UNC 都拒絕;缺檔、資料夾
  snapshot  從頭讀之後覆寫檔案，同版本的後續分塊仍是舊內容(不拼出兩個版本);舊版本從頭讀回 changed
  limit   閒置時限(3 秒)以 exit 124 結束、程序樹不留程序
  shared  與 app、主機服務共用的存取規則案例(vendor/purrdr-host/protocol/host-file-access.json 的 Windows 案例，只看路徑):家目錄設成
          共用案例的 Windows 家目錄(只改 PowerShell 程序內的 $env:USERPROFILE),不碰真的家目錄;放行回 missing、不放行回 denied

用法(要在 Windows 主機本機跑：測試檔寫在本機 %TEMP%):
  PURRDR_WINDOWS_HOST=user@127.0.0.1 PURRDR_WINDOWS_KEY=<私鑰> \
    python -I scripts/windows-file-fetch-repro.py [--kind binary|access|snapshot|limit|all]
全部綠 exit 0。只結束本次啟動的程序樹裡的程序(以 pid 與建立時間確認)。
"""
import argparse
import base64
import glob
import hashlib
import importlib.util
import json
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

REPLY_TIMEOUT = 30
CHUNK = 192 * 1024


def schema():
    """主機服務協定 schema(排除清單、大小上限的唯一定義)。"""
    with open(os.path.join(repro.REPO, "vendor", "purrdr-host", "protocol", "host-service.schema.json"), encoding="utf-8") as file:
        return json.load(file)


MAXIMUM = schema()["x-maximum-file-size"]


def core_source(file_name):
    found = glob.glob(os.path.join(repro.REPO, "src", "*", file_name))
    if len(found) != 1:
        sys.exit(f"src/*/{file_name} 找到 {len(found)} 份(要剛好一份):檔案搬家或改名了，請更新本腳本")
    with open(found[0], encoding="utf-8") as file:
        return file.read()


def fetch_settings():
    """同 `WindowsScripts.fetchSettings`。"""
    patterns = []
    for location in schema()["x-excluded-file-locations"]:
        lowered = location.lower()
        patterns += [f"*/{lowered}", f"*/{lowered}/*"]
    return "$purrdrExcluded=@(" + ",".join(repro.quote(p) for p in patterns) + f");$purrdrChunk={schema()['x-maximum-file-chunk']}"


def fetch_stdin(source, idle=60, total=600, maximum=MAXIMUM, preamble=""):
    script = "\n".join([
        preamble,
        repro.swift_literal(source, "prelude"),
        "$a=@(" + ",".join(repro.quote(str(v)) for v in (idle, total, maximum)) + ")",
        fetch_settings(),
        repro.swift_literal(source, "transcriptFunctions"),
        repro.swift_literal(source, "hostFileFunctions"),
        repro.swift_literal(source, "hostFileFetchScript"),
    ])
    return (script + "\n" + repro.swift_string(source, "endOfScript") + "\n").encode()


def b64(text):
    return base64.b64encode(text.encode()).decode()


class Fetcher:
    """一條長駐取檔通道(一個 ssh 程序)。"""

    def __init__(self, source, idle=60, total=600, verbose=False, preamble=""):
        remote = "cat /proc/$$/winpid >&2; " + repro.encoded(repro.stdin_stub(source))
        argv = repro.ssh_argv(remote)
        if verbose:
            argv.insert(1, "-v")
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.root = self.process.stderr.readline().decode().strip()
        self.stderr = b""
        self.chunks = queue.Queue()
        self.buffer = b""
        self.last_reply_bytes = 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        self.process.stdin.write(fetch_stdin(source, idle, total, preamble=preamble))
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
        """同 `HostFileFetchScript.takeReply`:回傳 (第一行欄位, chunk 內容);還不完整是 None。"""
        newline = self.buffer.find(b"\n")
        if newline < 0:
            return None
        fields = self.buffer[:newline].decode().split(" ")
        following = newline + 1
        data = None
        if fields[0] == "chunk":
            length = int(fields[3])
            if len(self.buffer) - following < length + 1:
                return None
            data = base64.b64decode(self.buffer[following:following + length], validate=True)
            if len(data) != int(fields[2]):
                raise RuntimeError(f"chunk 長度不符:{fields}")
            following += length + 1
        end = self.buffer.find(b"\n", following)
        if end < 0:
            return None
        if self.buffer[following:end] != b"end":
            raise RuntimeError(f"回應最後一行不是 end:{self.buffer[:200]!r}")
        self.last_reply_bytes = end + 1
        self.buffer = self.buffer[end + 1:]
        return fields, data

    def request(self, line, timeout=REPLY_TIMEOUT):
        self.process.stdin.write((line + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while (reply := self.take_reply()) is None:
            chunk = self.chunks.get(timeout=max(0.1, deadline - time.monotonic()))
            if chunk is None:
                raise EOFError(f"通道結束 exit={self.process.wait()} stderr={self.stderr[-300:]!r}")
            self.buffer += chunk
        return reply

    def stat(self, path, root=None):
        fields, _ = self.request(f"stat {b64(path)} {b64(root) if root else '-'}")
        return fields

    def read(self, path, root, version, offset, length=CHUNK):
        return self.request(f"read {b64(path)} {b64(root) if root else '-'} {version} {offset} {length}")

    def fetch(self, path, root=None):
        """查狀態後以 192 KiB 分塊讀完;回傳 (內容, 每輪 stdout 位元組)。"""
        fields = self.stat(path, root)
        if fields[0] != "file":
            raise RuntimeError(f"stat 不是 file:{fields}")
        version, size = fields[1], int(fields[2])
        content, rounds = b"", []
        while len(content) < size:
            reply_fields, data = self.read(path, root, version, len(content))
            if reply_fields[0] != "chunk" or not data:
                raise RuntimeError(f"讀到 {len(content)} 時回 {reply_fields}")
            content += data
            rounds.append(self.last_reply_bytes)
        return content, rounds

    def tree(self):
        return repro.host_tree(self.root) if self.root.isdigit() else []

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)
        time.sleep(0.2)
        return self.stderr


def samples():
    """自建的測試檔：檔頭是真的格式簽章，內容是亂數(含 NUL 與高位元組)。"""
    random = os.urandom
    return {
        "shot.png": b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + random(300 * 1024),
        "photo.jpg": b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + random(700 * 1024) + b"\xff\xd9",
        "report.pdf": b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n" + random(512 * 1024) + b"\n%%EOF\n",
        "bytes.bin": bytes(range(256)) * 1024 + b"\x00\r\n\x00\x1a\xff\xfe",
        "large.bin": random(MAXIMUM - 1),
    }


def remove(folder):
    """刪掉自建的測試資料夾(主機端程序剛結束時資料夾可能還被占用，重試幾次)。"""
    for _ in range(10):
        shutil.rmtree(folder, ignore_errors=True)
        if not os.path.exists(folder):
            return
        time.sleep(0.5)


def run_binary(source):
    folder = tempfile.mkdtemp(prefix="purrdr-fetch-")
    fetcher = Fetcher(source, verbose=True)
    trees, details, green = [], [], True
    try:
        for name, data in samples().items():
            path = os.path.join(folder, name)
            with open(path, "wb") as file:
                file.write(data)
            started = time.monotonic()
            content, rounds = fetcher.fetch(path, folder)
            trees = trees or fetcher.tree()
            same = hashlib.sha256(content).hexdigest() == hashlib.sha256(data).hexdigest()
            green &= same
            full = rounds[:-1] or rounds
            per_round = f"整塊每輪 {min(full)}–{max(full)} B、最後一輪 {rounds[-1]} B"
            details.append(f"{name} {len(data)} B {len(rounds)} 輪 {per_round}、合計 {sum(rounds)} B、"
                           f"{time.monotonic() - started:.1f}s、SHA-256 {'一致' if same else '不一致'} {hashlib.sha256(content).hexdigest()[:16]}")
        too_large = os.path.join(folder, "over.bin")
        with open(too_large, "wb") as file:
            file.write(b"\x00" * (MAXIMUM + 1))
        over = fetcher.stat(too_large, folder)
        green &= over == ["toolarge", str(MAXIMUM + 1)]
        details.append(f"上限 +1:{' '.join(over)}")
    finally:
        sent, received = repro_transferred(fetcher.close())
        details.append(f"SSH 層合計 送出 {sent} B、收到 {received} B")
        repro.stop_processes(repro.still_running(trees))
        remove(folder)
    return green, "\n         ".join(details)


def repro_transferred(stderr):
    match = re.search(rb"Transferred: sent (\d+), received (\d+) bytes", stderr)
    return (int(match.group(1)), int(match.group(2))) if match else (-1, -1)


def mklink(kind, link, target):
    completed = subprocess.run(["cmd.exe", "/c", "mklink", kind, link, target], capture_output=True)
    return completed.returncode == 0


def run_access(source):
    folder = tempfile.mkdtemp(prefix="purrdr-fetch-")
    root = os.path.join(folder, "Work")
    outside = os.path.join(folder, "Outside")
    secrets = os.path.join(folder, "Home", ".ssh")
    for directory in (root, outside, secrets, os.path.join(root, "docs"), os.path.join(root, ".SSH")):
        os.makedirs(directory, exist_ok=True)
    for path in (os.path.join(root, "docs", "a.png"), os.path.join(outside, "b.png"), os.path.join(secrets, "id_ed25519"),
                 os.path.join(root, ".SSH", "config")):
        with open(path, "wb") as file:
            file.write(b"\x89PNG\r\n\x1a\nsecret")
    mklink("/J", os.path.join(root, "out"), outside)
    mklink("/J", os.path.join(root, "keys"), secrets)
    mklink("/J", os.path.join(root, "inner"), os.path.join(root, "docs"))
    has_symlink = mklink("", os.path.join(root, "link.png"), os.path.join(outside, "b.png"))
    fetcher = Fetcher(source)
    trees = []
    try:
        drive = root[0]
        other_drive = "Z" if drive.upper() != "Z" else "Y"
        cases = [
            ("工作目錄之下", os.path.join(root, "docs", "a.png"), root, "file"),
            ("工作目錄大小寫不同", os.path.join(root, "docs", "a.png").upper(), root.lower(), "file"),
            ("磁碟機代號小寫、/ 分隔", (drive.lower() + os.path.join(root, "docs", "a.png")[1:]).replace("\\", "/"), root, "file"),
            ("junction 指到工作目錄之內", os.path.join(root, "inner", "a.png"), root, "file"),
            ("對話紀錄出現過(無工作目錄)", os.path.join(outside, "b.png"), None, "file"),
            ("junction 跳出工作目錄", os.path.join(root, "out", "b.png"), root, "denied"),
            ("junction 指到排除清單", os.path.join(root, "keys", "id_ed25519"), root, "denied"),
            ("排除清單大小寫不同", os.path.join(root, ".SSH", "config"), root, "denied"),
            ("排除清單(無工作目錄)", os.path.join(secrets, "id_ed25519"), None, "denied"),
            ("工作目錄之外", os.path.join(outside, "b.png"), root, "denied"),
            ("別的磁碟機", other_drive + os.path.join(root, "docs", "a.png")[1:], root, "denied"),
            ("相對路徑", "docs\\a.png", root, "denied"),
            ("ADS", os.path.join(root, "docs", "a.png") + ":hidden", root, "denied"),
            ("UNC", "\\\\localhost\\" + drive + "$" + os.path.join(root, "docs", "a.png")[2:], None, "denied"),
            ("..跳出", os.path.join(root, "..", "Outside", "b.png"), root, "denied"),
            ("缺檔", os.path.join(root, "docs", "nope.png"), root, "missing"),
            ("資料夾", os.path.join(root, "docs"), root, "other"),
        ]
        if has_symlink:
            cases.append(("symbolic link 跳出工作目錄", os.path.join(root, "link.png"), root, "denied"))
        results = []
        green = True
        for label, path, case_root, expected in cases:
            verdict = fetcher.stat(path, case_root)[0]
            trees = trees or fetcher.tree()
            ok = verdict == expected
            green &= ok
            results.append(f"{label} {verdict}{'' if ok else f'(應為 {expected})'}")
        if not has_symlink:
            results.append("symbolic link 建不了(要開發人員模式或系統管理員),略過")
        return green, " · ".join(results)
    finally:
        fetcher.close()
        repro.stop_processes(repro.still_running(trees))
        for link in ("out", "keys", "inner"):
            subprocess.run(["cmd.exe", "/c", "rmdir", os.path.join(root, link)], capture_output=True)
        remove(folder)


def run_shared(source):
    """共用案例(只看路徑):PowerShell 程序內把家目錄指到共用案例裡不存在的家目錄。"""
    with open(os.path.join(repro.REPO, "vendor", "purrdr-host", "protocol", "host-file-access.json"), encoding="utf-8") as file:
        vectors = json.load(file)
    home = vectors["environment"]["windows"]["home"]
    # TEMP 不改：Add-Type 要在真的暫存目錄編譯;家目錄底下的 AppData\Local\Temp 由 USERPROFILE 推得。
    preamble = f"$env:USERPROFILE={repro.quote(home)}"
    cases = [case for case in vectors["accessCases"]
             if case["platform"] == "windows" and "powershell" in case.get("only", ["powershell"])]
    fetcher = Fetcher(source, preamble=preamble)
    trees, failures, green = [], [], True
    try:
        for case in cases:
            verdict = fetcher.stat(case["path"], case["root"])[0]
            trees = trees or fetcher.tree()
            ok = (verdict == "denied") == (case["expected"] == "denied")
            green &= ok
            if not ok:
                failures.append(f"{case['name']} {verdict}(應為 {case['expected']})")
        return green, f"{len(cases)} 個案例" + ("" if green else ":" + " · ".join(failures))
    finally:
        fetcher.close()
        repro.stop_processes(repro.still_running(trees))


def run_snapshot(source):
    folder = tempfile.mkdtemp(prefix="purrdr-fetch-")
    path = os.path.join(folder, "shot.png")
    original = os.urandom(600 * 1024)
    with open(path, "wb") as file:
        file.write(original)
    fetcher = Fetcher(source)
    trees = []
    try:
        fields = fetcher.stat(path, folder)
        version = fields[1]
        trees = fetcher.tree()
        first = fetcher.read(path, folder, version, 0)[1]
        replacement = os.urandom(600 * 1024)
        with open(path, "wb") as file:
            file.write(replacement)
        rest = b""
        while len(first) + len(rest) < len(original):
            rest += fetcher.read(path, folder, version, len(first) + len(rest))[1]
        assembled = first + rest
        restart = fetcher.read(path, folder, version, 0)[0]
        checks = {
            "覆寫後仍拼出舊版本": assembled == original,
            "舊版本從頭讀 changed": restart == ["changed"],
        }
        return all(checks.values()), " · ".join(f"{name} {'OK' if ok else 'NG'}" for name, ok in checks.items())
    finally:
        fetcher.close()
        repro.stop_processes(repro.still_running(trees))
        remove(folder)


def run_limit(source):
    folder = tempfile.mkdtemp(prefix="purrdr-fetch-")
    fetcher = Fetcher(source, idle=3, total=60)
    trees = []
    try:
        fetcher.stat(os.path.join(folder, "nope.png"), folder)
        started = time.monotonic()
        trees = fetcher.tree()
        fetcher.process.wait(timeout=20)
        elapsed = time.monotonic() - started
        time.sleep(1)
        left = repro.still_running(trees)
        repro.stop_processes(left)
        green = fetcher.process.returncode == 124 and 2 <= elapsed <= 8 and not left
        return green, f"閒置 3s:{elapsed:.1f}s exit={fetcher.process.returncode},程序樹 {len(trees)} 個、留下 {len(left)} 個"
    finally:
        if fetcher.process.poll() is None:
            fetcher.process.kill()
        repro.stop_processes(repro.still_running(trees))
        remove(folder)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--kind", choices=["binary", "access", "shared", "snapshot", "limit", "all"], default="all")
    options = parser.parse_args()
    if os.name != "nt":
        sys.exit("要在 Windows 主機本機跑(測試檔直接寫在本機 %TEMP%)")
    source = repro.swift_source()
    runs = {"binary": run_binary, "access": run_access, "shared": run_shared, "snapshot": run_snapshot, "limit": run_limit}
    all_green = True
    for kind in (list(runs) if options.kind == "all" else [options.kind]):
        try:
            green, detail = runs[kind](source)
        except Exception as error:  # 一個案例出錯不影響其他案例
            green, detail = False, f"{type(error).__name__}: {error}"
        all_green &= green
        print(f"{'GREEN' if green else 'RED  '} {kind:8} {detail}", flush=True)
    print("全部綠燈" if all_green else "有紅燈")
    sys.exit(0 if all_green else 1)


if __name__ == "__main__":
    main()
