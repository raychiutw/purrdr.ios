"""Windows 長駐追蹤腳本(#167)經真正 sshd 的回歸檢查：stdin 多輪不卡、時限、關閉與斷線後不留程序。

腳本從 Swift 原始碼抽出(共用 `windows-upload-repro.py` 的抽取函式):stub 照 `WindowsCommand.viaStdin`,腳本照
`WindowsScripts.transcript(WindowsScripts.follow, …)`;stdin 送完腳本與結束標記後不送 EOF,接著一行一個請求
「游標 版本 錨點 路徑」,回應照 `SSHTranscriptFollower.takeReply` 的格式解析。

kind:
  cases   回應種類：附加(剝圖片、未完成的行不送)、沒變、同時間同長的新檔、變短、同長以上的新檔、檔案不在。
  stress  N 條通道(各自一條 ssh 連線、一個檔)並行 R 輪：每輪隨機附加 0／1 KiB／200 KiB,每 25 輪附加 2 MiB;
          最後追上，收到的行要與寫入的完全相同。結束方式 `--end close`(送 EOF)或 `drop`(直接結束本機 ssh,斷 TCP),
          3 秒後程序樹(以 Git Bash 的 `/proc/$$/winpid` 為根)不留任何程序。
  limit   閒置時限(只送一個請求)與總長時限(每秒一個請求)都以 exit 124 結束、不留程序(時限換短)。
  control 對照組：請求改用 `[Console]::In.ReadLine()` 讀，預期卡住(確認 stress 抓得到 #77)。

用法(要在 Windows 主機本機跑：對話紀錄檔直接寫在本機 %TEMP%):
  PURRDR_WINDOWS_HOST=user@127.0.0.1 PURRDR_WINDOWS_KEY=<私鑰> \
    python -I scripts/windows-follow-repro.py [--kind cases|stress|limit|control|all] [--channels 4] [--rounds 100] [--end close|drop|all]
全部綠 exit 0。只結束本次啟動的程序樹裡的程序(以 pid 與建立時間確認)。
"""
import argparse
import importlib.util
import os
import queue
import random
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

# `TranscriptReader.catchUpLimit`、`catchUpBacklogLimit`;時限照 `HostScriptTimeLimit.followIdleSeconds`／`followTotalSeconds`。
LIMIT, BACKLOG = 65_536, 1_048_576
REPLY_TIMEOUT = 20


def follow_stdin(source, idle, total, control=False):
    """stdin 的腳本部分：PowerShell 版追蹤腳本 + 結束標記。"""
    body = repro.swift_literal(source, "follow")
    if control:
        body = body.replace("$s.ReadLine()", "[Console]::In.ReadLine()")
    script = "\n".join([
        repro.swift_literal(source, "prelude"),
        "$a=@(" + ",".join(repro.quote(str(v)) for v in (LIMIT, BACKLOG, idle, total)) + ")",
        repro.swift_literal(source, "transcriptFunctions"),
        body,
    ])
    return (script + "\n" + repro.swift_string(source, "endOfScript") + "\n").encode()


class Follower:
    """一條長駐追蹤通道(一個 ssh 程序)。"""

    def __init__(self, source, idle=60, total=600, control=False):
        remote = "cat /proc/$$/winpid >&2; " + repro.encoded(repro.stdin_stub(source))
        self.process = subprocess.Popen(repro.ssh_argv(remote), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.root = self.process.stderr.readline().decode().strip()
        self.lines = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.process.stdin.write(follow_stdin(source, idle, total, control))
        self.process.stdin.flush()
        self.cursor, self.stamp, self.anchor = 0, "-", "-"
        self.received = []

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line.rstrip(b"\n").decode("utf-8", errors="replace"))
        self.lines.put(None)

    def line(self, timeout):
        line = self.lines.get(timeout=timeout)
        if line is None:
            raise EOFError(f"通道結束 exit={self.process.wait()}")
        return line

    def poll(self, path, timeout=REPLY_TIMEOUT):
        """送一個請求，回傳回應種類;`appended` 時更新游標並把行(去掉原始長度)收進 `received`。"""
        self.process.stdin.write(f"{self.cursor} {self.stamp} {self.anchor} {path}\n".encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        words = self.line(timeout).split(" ")
        if words[0] in ("unchanged", "replaced", "error"):
            return " ".join(words)
        if words[0] != "appended" or len(words) != 3:
            raise RuntimeError(f"看不懂的回應 {words!r}")
        size, stamp, records = int(words[1]), words[2], []
        while True:
            line = self.line(max(0.1, deadline - time.monotonic()))
            if line.startswith("end "):
                _, end, anchor = line.split(" ")
                start = self.cursor
                if sum(int(r.split("\t", 1)[0]) + 1 for r in records) != int(end) - start:
                    raise RuntimeError(f"行的原始長度合計與游標 {start}→{end} 不符")
                # 同 `SSHTranscriptFollower.dropsStampIfCapped`:落後超過一次讀的上限時不留版本。
                self.cursor, self.stamp, self.anchor = int(end), stamp if size - start <= BACKLOG else "-", anchor
                self.received += [r.split("\t", 1)[1] for r in records]
                return "appended"
            records.append(line)

    def tree(self):
        return repro.host_tree(self.root) if self.root.isdigit() else []


def text_line(index, size):
    """約 `size` bytes 的一行(不會被剝圖片規則吃掉)。"""
    head = f'{{"n":{index},"text":"'
    return head + ("purrdr " * (size // 7 + 1))[: max(0, size - len(head) - 2)] + '"}'


def run_channel(index, source, folder, rounds, record):
    path = os.path.join(folder, f"follow-{index}.jsonl")
    written = [text_line(0, 100)]
    with open(path, "wb") as file:
        file.write((written[0] + "\n").encode())
    follower = Follower(source)
    record.update(follower=follower, rounds=0, max_ms=0, error=None)
    random_source = random.Random(index)
    try:
        for round_index in range(rounds):
            choice = random_source.random()
            if round_index % 25 == 24:
                count = 2048
            elif choice < 0.3:
                count = 1
            elif choice < 0.4:
                count = 200
            else:
                count = 0
            new = [text_line(round_index * 10_000 + k, 1023) for k in range(count)]
            if new:
                with open(path, "ab") as file:
                    file.write("".join(line + "\n" for line in new).encode())
                written += new
            started = time.perf_counter()
            follower.poll(path)
            record["max_ms"] = max(record["max_ms"], round((time.perf_counter() - started) * 1000))
            record["rounds"] += 1
        size = os.path.getsize(path)
        catch_up = 0
        while follower.cursor < size and catch_up < 10:
            follower.poll(path)
            catch_up += 1
        if follower.cursor != size or follower.received != written:
            record["error"] = f"追上後游標 {follower.cursor}/{size},行 {len(follower.received)}/{len(written)} 筆" + (
                "" if follower.received == written[: len(follower.received)] else ",內容不同")
        record["unchanged"] = follower.poll(path)
    except Exception as error:  # noqa: BLE001 - 記下哪一輪失敗
        record["error"] = f"第 {record['rounds']} 輪：{error!r}"


def finish(followers, end):
    """依 `end` 結束所有通道;3 秒後回傳還留著的程序。"""
    trees = []
    for follower in followers:
        trees += [p for p in follower.tree() if p not in trees]
    for follower in followers:
        if end == "close":
            follower.process.stdin.close()
        else:
            follower.process.kill()
    time.sleep(3)
    left = repro.still_running(trees)
    repro.stop_processes(left)
    for follower in followers:
        if follower.process.poll() is None:
            follower.process.kill()
    return trees, left


def run_stress(source, channels, rounds, end, control=False):
    folder = tempfile.mkdtemp(prefix="purrdr-follow-")
    try:
        records = [{} for _ in range(channels)]
        workers = [threading.Thread(target=run_channel if not control else run_control, args=(index, source, folder, rounds, records[index]),
                                    daemon=True) for index in range(channels)]
        started = time.monotonic()
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=rounds * REPLY_TIMEOUT + 60)
        elapsed = time.monotonic() - started
        followers = [record["follower"] for record in records if "follower" in record]
        trees, left = finish(followers, end)
        errors = [f"通道 {i}:{r.get('error')}" for i, r in enumerate(records) if r.get("error")]
        summary = (f"{channels} 通道 × {rounds} 輪 {elapsed:.0f}s,每通道完成 {[r.get('rounds') for r in records]} 輪、"
                   f"最長一輪 {max((r.get('max_ms', 0) for r in records), default=0)} ms;{end} 後 3 秒程序樹 {len(trees)} 個、留下 {len(left)} 個")
        if control:
            stuck = [r for r in records if r.get("error")]
            # 對照組要卡住、斷線後也留著程序(證明 stress 的檢查抓得到;留下的已以 pid 結束)。
            return bool(stuck) and bool(left), summary + f";卡住的通道 {len(stuck)} 條(對照組預期卡住並留下程序)"
        return not errors and not left, summary + ("" if not errors else ";" + ";".join(errors))
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def run_control(index, source, folder, rounds, record):
    """對照組：同 stress,只換掉讀請求的方式。"""
    path = os.path.join(folder, f"control-{index}.jsonl")
    with open(path, "wb") as file:
        file.write((text_line(0, 100) + "\n").encode())
    follower = Follower(source, control=True)
    record.update(follower=follower, rounds=0, max_ms=0, error=None)
    random_source = random.Random(index)
    try:
        for round_index in range(rounds):
            count = 2048 if round_index % 25 == 24 else (200 if random_source.random() < 0.4 else 1)
            with open(path, "ab") as file:
                file.write("".join(text_line(k, 1023) + "\n" for k in range(count)).encode())
            follower.poll(path)
            record["rounds"] += 1
    except Exception as error:  # noqa: BLE001
        record["error"] = f"第 {record['rounds']} 輪：{error!r}"


def run_limit(source, case):
    """`idle`:閒置 3 秒、總長 60 秒，只送一個請求。`total`:閒置 3 秒、總長 8 秒，每秒一個請求。"""
    folder = tempfile.mkdtemp(prefix="purrdr-follow-")
    path = os.path.join(folder, "limit.jsonl")
    with open(path, "wb") as file:
        file.write((text_line(0, 100) + "\n").encode())
    idle, total = (3, 60) if case == "idle" else (3, 8)
    follower = Follower(source, idle=idle, total=total)
    trees = []
    try:
        follower.poll(path)
        # 從第一個回應起算(PowerShell 啟動 0.6～2.5 秒不算在時限裡)。
        started = time.monotonic()
        trees = follower.tree()
        replies = 1
        while follower.process.poll() is None and time.monotonic() - started < total + 10:
            if case == "total":
                try:
                    follower.poll(path, timeout=2)
                    replies += 1
                except (EOFError, queue.Empty):
                    pass
            time.sleep(1 if case == "total" else 0.2)
        follower.process.wait(timeout=5)
        elapsed = time.monotonic() - started
        time.sleep(1)
        left = repro.still_running(trees)
        repro.stop_processes(left)
        expected = idle if case == "idle" else total
        # 實測到時限後 PowerShell 還要 2～3 秒才結束([Environment]::Exit 的收尾)。
        in_time = expected - 1 <= elapsed <= expected + 5
        green = follower.process.returncode == 124 and in_time and not left
        return green, (f"時限 {expected}s:{elapsed:.1f}s exit={follower.process.returncode},回應 {replies} 次，"
                       f"程序樹 {len(trees)} 個、留下 {len(left)} 個")
    finally:
        if follower.process.poll() is None:
            follower.process.kill()
        repro.stop_processes(repro.still_running(trees))
        shutil.rmtree(folder, ignore_errors=True)


def run_cases(source):
    """回應種類：附加(圖片字串剝掉)、沒變、變短、同長新檔(錨點)、檔案不在。"""
    folder = tempfile.mkdtemp(prefix="purrdr-follow-")
    path = os.path.join(folder, "cases.jsonl")
    image = '{"n":2,"image":"' + "A" * 200 + '"}'
    with open(path, "wb") as file:
        file.write(b'{"n":1}\n')
    follower = Follower(source)
    trees = []
    try:
        steps = [("第一次", follower.poll(path))]
        trees = follower.tree()
        with open(path, "ab") as file:
            file.write((image + "\n" + '{"n":3,"partial"').encode())
        steps.append(("附加", follower.poll(path)))
        stripped = follower.received[-1:] == ['{"n":2,"image":""}'] and follower.cursor == 8 + len(image) + 1
        steps.append(("沒變", follower.poll(path)))
        cursor, stamp, anchor = follower.cursor, follower.stamp, follower.anchor
        # 同一時間換成同長的新檔：版本(修改時間 ticks-大小)相同，只有錨點看得出來。
        before = os.stat(path)
        with open(path, "rb") as file:
            same_length = file.read().replace(b"A", b"B")
        with open(path, "wb") as file:
            file.write(same_length)
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        steps.append(("同時間同長的新檔", follower.poll(path)))
        follower.cursor, follower.stamp, follower.anchor = cursor, stamp, anchor
        with open(path, "wb") as file:
            file.write(b"x\n")
        steps.append(("變短", follower.poll(path)))
        with open(path, "wb") as file:
            file.write(b"y" * (cursor - 1) + b"\n" + b"z\n")
        follower.cursor, follower.stamp, follower.anchor = cursor, stamp, anchor
        steps.append(("同長以上的新檔", follower.poll(path)))
        steps.append(("檔案不在", follower.poll(path + ".missing")))
        expected = ["appended", "appended", "unchanged", f"replaced {before.st_size}", "replaced 2", f"replaced {cursor + 2}", "error 3"]
        got = [reply for _, reply in steps]
        green = got == expected and stripped
        return green, " · ".join(f"{name} {reply}" for name, reply in steps) + ("" if stripped else ";圖片字串沒剝掉或游標不對")
    finally:
        follower.process.stdin.close()
        follower.process.wait(timeout=10)
        repro.stop_processes(repro.still_running(trees))
        shutil.rmtree(folder, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--kind", choices=["cases", "stress", "limit", "control", "all"], default="all")
    parser.add_argument("--channels", type=int, default=4)
    parser.add_argument("--rounds", type=int, default=100)
    parser.add_argument("--end", choices=["close", "drop", "all"], default="all")
    options = parser.parse_args()
    if os.name != "nt":
        sys.exit("要在 Windows 主機本機跑(對話紀錄檔直接寫在本機 %TEMP%)")
    source = repro.swift_source()
    all_green = True
    kinds = ["cases", "stress", "limit", "control"] if options.kind == "all" else [options.kind]
    ends = ["close", "drop"] if options.end == "all" else [options.end]
    for kind in kinds:
        if kind == "cases":
            results = [("cases", *run_cases(source))]
        elif kind == "limit":
            results = [(f"limit {case}", *run_limit(source, case)) for case in ("idle", "total")]
        elif kind == "control":
            results = [("control", *run_stress(source, options.channels, min(options.rounds, 30), "drop", control=True))]
        else:
            results = [(f"stress {end}", *run_stress(source, options.channels, options.rounds, end)) for end in ends]
        for label, green, detail in results:
            all_green &= green
            print(f"{'GREEN' if green else 'RED  '} {label:16} {detail}", flush=True)
    print("全部綠燈" if all_green else "有紅燈")
    sys.exit(0 if all_green else 1)


if __name__ == "__main__":
    main()
