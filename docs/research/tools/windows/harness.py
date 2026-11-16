"""經 SSH 在 Windows 實測機執行一個指令，依腳本寫 stdin,記錄 stdout/stderr 的時間序。

用法(由其他腳本 import):run(name, remote_cmd, steps, timeout)
steps: list of ("send", str) | ("sleep", sec) | ("eof",) | ("wait_stdout", n_lines, timeout)
輸出:raw/<name>.transcript.ndjson、<name>.stdout(原始 bytes)、<name>.stderr
"""
import json, os, subprocess, threading, time, base64

# 實測機：PURRDR_WIN_SSH=<user@host>,PURRDR_WIN_SSH_KEY=<私鑰路徑>(可省略)。登入後的預設 shell 是 Git Bash。
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"] + (
    ["-i", os.path.expanduser(os.environ["PURRDR_WIN_SSH_KEY"])] if os.environ.get("PURRDR_WIN_SSH_KEY") else []
) + [os.environ["PURRDR_WIN_SSH"]]
HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")
os.makedirs(RAW, exist_ok=True)


def encoded(script, exe="powershell.exe"):
    b64 = base64.b64encode(script.encode("utf-16-le")).decode()
    return f"{exe} -NoLogo -NoProfile -NonInteractive -EncodedCommand {b64}"


def run(name, remote_cmd, steps, timeout=30):
    t0 = time.monotonic()
    log = []
    lock = threading.Lock()

    def rec(direction, line):
        with lock:
            log.append({"t_ms": round((time.monotonic() - t0) * 1000, 1), "dir": direction, "line": line})

    p = subprocess.Popen(SSH + [remote_cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out_raw = bytearray()
    err_raw = bytearray()
    out_lines = []

    def read_out():
        buf = b""
        while True:
            chunk = p.stdout.read1(65536)
            if not chunk:
                break
            out_raw.extend(chunk)
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                out_lines.append(line)
                rec("stdout", line.decode("utf-8", "replace"))
        if buf:
            rec("stdout_partial", buf.decode("utf-8", "replace"))
        rec("stdout_eof", None)

    def read_err():
        for line in p.stderr:
            err_raw.extend(line)
            rec("stderr", line.decode("utf-8", "replace").rstrip("\n"))

    to = threading.Thread(target=read_out); to.start()
    te = threading.Thread(target=read_err); te.start()
    try:
        for step in steps:
            kind = step[0]
            if kind == "send":
                rec("stdin", step[1])
                try:
                    p.stdin.write(step[1].encode() + b"\n"); p.stdin.flush()
                except BrokenPipeError:
                    rec("stdin_broken_pipe", None)
            elif kind == "sleep":
                time.sleep(step[1])
            elif kind == "eof":
                rec("stdin_eof", None)
                try:
                    p.stdin.close()
                except BrokenPipeError:
                    pass
            elif kind == "wait_stdout":
                n, limit = step[1], step[2]
                end = time.monotonic() + limit
                while len(out_lines) < n and time.monotonic() < end and p.poll() is None:
                    time.sleep(0.01)
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            rec("timeout_kill", None)
            p.kill(); p.wait()
    finally:
        to.join(); te.join()
    rec("exit", p.returncode)
    with open(os.path.join(RAW, name + ".transcript.ndjson"), "w") as f:
        for e in log:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    open(os.path.join(RAW, name + ".stdout"), "wb").write(bytes(out_raw))
    open(os.path.join(RAW, name + ".stderr"), "wb").write(bytes(err_raw))
    return log, p.returncode


def summary(name, log, code):
    print(f"== {name} exit={code}")
    for e in log:
        line = e["line"]
        if isinstance(line, str) and len(line) > 220:
            line = line[:220] + f"...(+{len(e['line'])-220})"
        print(f"  {e['t_ms']:>8} {e['dir']:<12} {line}")
