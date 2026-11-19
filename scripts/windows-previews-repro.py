"""Windows 列表預覽帶已知版本(#205)經真正 sshd 的回歸檢查。

腳本從 Swift 原始碼抽出(共用 `windows-upload-repro.py` 的抽取函式):stub 照 `WindowsCommand.viaStdin`,
預覽腳本照 `WindowsScripts.transcript(WindowsScripts.previews, …)`。對話紀錄以「path」種類指定，寫在本機 %TEMP% 的暫存資料夾。

案例(同一個檔，依序):第一次 whole、沒變 unchanged 且不送內容、附加一行只送附加的部分、
換成同長的新檔 whole、換成較短的新檔 whole。

用法(要在 Windows 主機本機跑):
  PURRDR_WINDOWS_HOST=user@127.0.0.1 PURRDR_WINDOWS_KEY=<私鑰> python -I scripts/windows-previews-repro.py
全部綠 exit 0。每次讀取是一條 ssh 連線，逾時由 subprocess 結束本次啟動的 ssh。
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("upload_repro", os.path.join(HERE, "windows-upload-repro.py"))
repro = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(repro)

MARKER = "purrdr-preview-marker"
KEY = "chat"


def previews_stdin(source, path, known):
    """stdin 的腳本部分(同 `WindowsScripts.transcript`),接著結束標記。"""
    arguments = [MARKER, KEY, "path", path, "", known]
    script = "\n".join([
        repro.swift_literal(source, "prelude"),
        "$a=@(" + ",".join(repro.quote(value) for value in arguments) + ")",
        repro.swift_literal(source, "transcriptFunctions"),
        repro.swift_literal(source, "previews"),
    ])
    return (script + "\n" + repro.swift_string(source, "endOfScript") + "\n").encode()


def read_previews(source, path, known):
    """一次預覽讀取：回傳(範圍, 版本, 內容)。"""
    completed = subprocess.run(repro.ssh_argv(repro.encoded(repro.stdin_stub(source))),
                               input=previews_stdin(source, path, known), capture_output=True, timeout=60)
    lines = completed.stdout.replace(b"\r\n", b"\n").decode("utf-8", errors="replace").split("\n")
    range_prefix = f"{MARKER}@ {KEY} "
    for index, line in enumerate(lines):
        if line.startswith(range_prefix):
            change, _, version = line[len(range_prefix):].partition(" ")
            body = "\n".join(lines[index + 1:]).strip("\n")
            return change, version, body
    raise RuntimeError("沒有範圍行:" + completed.stdout[-300:].decode(errors="replace") + completed.stderr[-300:].decode(errors="replace"))


def line(number, text):
    return ('{"type":"assistant","uuid":"u%04d","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n'
            % (number, text)).encode()


def write(path, data, mode="wb"):
    with open(path, mode) as file:
        file.write(data)


def main():
    if os.name != "nt":
        sys.exit("要在 Windows 主機本機跑(對話紀錄直接寫在本機 %TEMP%)")
    source = repro.swift_source()
    folder = tempfile.mkdtemp(prefix="purrdr-previews-")
    path = os.path.join(folder, "session.jsonl")
    try:
        write(path, line(1, "first reply") + line(2, "second reply"))
        first = read_previews(source, path, "")
        unchanged = read_previews(source, path, first[1])
        write(path, line(3, "third reply"), mode="ab")
        appended = read_previews(source, path, first[1])
        write(path, line(1, "FIRST REPLY") + line(2, "SECOND REPLY") + line(3, "THIRD REPLY"))
        same_length = read_previews(source, path, appended[1])
        write(path, line(9, "short"))
        shorter = read_previews(source, path, same_length[1])
        checks = {
            "第一次 whole": first[0] == "whole" and "second reply" in first[2],
            "沒變 unchanged、不送內容": unchanged[0] == "unchanged" and unchanged[1] == first[1] and unchanged[2] == "",
            "附加只送新的一行": appended[0] == "appended" and "third reply" in appended[2] and "second reply" not in appended[2],
            "同長的新檔 whole": same_length[0] == "whole" and "THIRD REPLY" in same_length[2],
            "較短的新檔 whole": shorter[0] == "whole" and "short" in shorter[2],
        }
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    for name, ok in checks.items():
        print(f"{'GREEN' if ok else 'RED  '} {name}", flush=True)
    green = all(checks.values())
    print("全部綠燈" if green else "有紅燈")
    sys.exit(0 if green else 1)


if __name__ == "__main__":
    main()
