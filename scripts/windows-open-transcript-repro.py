"""Windows 點進聊天的合併讀取指令(#660)經真正 sshd 的回歸檢查。

腳本從 Swift 原始碼抽出(共用 `windows-upload-repro.py` 的抽取函式):stub 照 `WindowsCommand.viaStdin`,
合併腳本照 `WindowsScripts.open`(「path」種類的定位 + `openWindowSetup` + `windowBody`)。對話紀錄寫在本機 %TEMP% 的暫存資料夾。

案例:
  1. 一般檔案:最後 N 行,輸出是「路徑、大小、分隔行、起點 終點、每行」,游標等於檔案大小。
  2. maxBytes:只取範圍內完整的行,不放大區塊。
  3. 檔尾全是工具步驟與大圖片行:圖片 base64 被剝掉、原始長度照實印。
  4. 檔案不在:exit 3。
  5. 檔案在讀取途中變長:視窗終點是定位時量到的大小,每一行都完整、終點不超過實際大小。
  6. 時限:stdin 不送結束標記,stub 在 30 秒後以 exit 124 結束。

用法(要在 Windows 主機本機跑):
  PURRDR_WINDOWS_HOST=user@127.0.0.1 PURRDR_WINDOWS_KEY=<私鑰> python -I scripts/windows-open-transcript-repro.py
全部綠 exit 0。每次讀取是一條 ssh 連線,逾時由 subprocess 結束本次啟動的 ssh。
"""
import importlib.util
import os
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

MARKER = "purrdr-window"


def open_stdin(source, path, lines, max_bytes, with_end=True):
    """stdin 的腳本部分(同 `WindowsScripts.transcript` + `WindowsScripts.open`),接著結束標記。"""
    arguments = [path, "", str(lines), str(max_bytes)]
    locate = "\n".join(["$f=PFind 'path' $a[0] ''", "$z=PProbe $f", 'PWrite "$f`n$z`n"'])
    script = "\n".join([
        repro.swift_literal(source, "prelude"),
        "$a=@(" + ",".join(repro.quote(value) for value in arguments) + ")",
        repro.swift_literal(source, "transcriptFunctions"),
        "PRunBlock {", locate, repro.swift_literal(source, "openWindowSetup"), repro.swift_literal(source, "windowBody"), "}",
    ])
    tail = repro.swift_string(source, "endOfScript") + "\n" if with_end else ""
    return (script + "\n" + tail).encode()


def run_open(source, path, lines, max_bytes, timeout=60):
    """一次合併讀取:回傳(exit code, 路徑, 大小, 分隔行, 範圍, [(原始長度, 行)])。"""
    completed = subprocess.run(repro.ssh_argv(repro.encoded(repro.stdin_stub(source))),
                               input=open_stdin(source, path, lines, max_bytes), capture_output=True, timeout=timeout)
    text = completed.stdout.replace(b"\r\n", b"\n").decode("utf-8", errors="replace").split("\n")
    if completed.returncode != 0 or len(text) < 4:
        return completed.returncode, None, None, None, None, []
    start, end = (int(value) for value in text[3].split(" "))
    rows = []
    for row in text[4:]:
        if row == "":
            continue
        length, _, content = row.partition("\t")
        rows.append((int(length), content))
    return 0, text[0], int(text[1]), text[2], (start, end), rows


def line(number, extra=""):
    return ('{"type":"assistant","n":%d%s}\n' % (number, extra)).encode()


def write(path, data, mode="wb"):
    with open(path, mode) as file:
        file.write(data)


def main():
    if os.name != "nt":
        sys.exit("要在 Windows 主機本機跑(對話紀錄直接寫在本機 %TEMP%)")
    source = repro.swift_source()
    folder = tempfile.mkdtemp(prefix="purrdr-open-")
    path = os.path.join(folder, "session.jsonl")
    checks = {}
    try:
        # 1. 一般檔案
        write(path, b"".join(line(n) for n in range(1, 11)))
        size = os.path.getsize(path)
        code, got_path, got_size, marker, span, rows = run_open(source, path, 3, 0)
        checks["一般檔案:最後 3 行、游標等於大小"] = (
            code == 0 and got_path == path and got_size == size and marker == MARKER and span[1] == size
            and [content for _, content in rows] == ['{"type":"assistant","n":%d}' % n for n in (8, 9, 10)]
            and all(length == len(content) + 1 for length, content in rows))
        # 2. maxBytes
        code, _, _, _, span, rows = run_open(source, path, 300, 60)
        checks["maxBytes:只取範圍內完整的行"] = code == 0 and 0 < len(rows) < 10 and span[1] == size and span[0] > 0
        # 3. 檔尾全是工具步驟與大圖片行
        blob = "A" * 4000
        write(path, b"".join(line(n, ',"tool":"Read"') for n in range(1, 6)) + line(6, ',"image":"%s"' % blob))
        size = os.path.getsize(path)
        code, _, _, _, span, rows = run_open(source, path, 300, 0)
        checks["圖片 base64 剝掉、原始長度照實印"] = (
            code == 0 and len(rows) == 6 and rows[-1][1].endswith('"image":""}') and rows[-1][0] > 4000 and span[1] == size)
        # 4. 檔案不在
        code = run_open(source, os.path.join(folder, "missing.jsonl"), 3, 0)[0]
        checks["檔案不在:exit 3"] = code == 3
        # 5. 讀取途中變長
        write(path, b"".join(line(n) for n in range(1, 2001)))
        stop = threading.Event()

        def grow():
            number = 3000
            while not stop.is_set():
                write(path, line(number), mode="ab")
                number += 1
                time.sleep(0.01)

        thread = threading.Thread(target=grow)
        thread.start()
        try:
            code, _, got_size, _, span, rows = run_open(source, path, 300, 0)
        finally:
            stop.set()
            thread.join()
        final = os.path.getsize(path)
        checks["途中變長:終點是定位時的大小、行完整"] = (
            code == 0 and span[1] == got_size <= final and len(rows) == 300
            and all(content.startswith("{") and content.endswith("}") for _, content in rows))
        # 6. 時限(stdin 不送結束標記)
        started = time.time()
        completed = subprocess.run(repro.ssh_argv(repro.encoded(repro.stdin_stub(source))),
                                   input=open_stdin(source, path, 3, 0, with_end=False), capture_output=True, timeout=120)
        elapsed = time.time() - started
        checks["時限:沒有結束標記 30 秒後 exit 124"] = completed.returncode == 124 and 25 < elapsed < 60
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    for name, ok in checks.items():
        print(f"{'GREEN' if ok else 'RED  '} {name}", flush=True)
    green = all(checks.values())
    print("全部綠燈" if green else "有紅燈")
    sys.exit(0 if green else 1)


if __name__ == "__main__":
    main()
