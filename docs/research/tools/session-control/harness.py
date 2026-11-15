"""Drive `herdr terminal session control/observe` and record a timed transcript.
usage: harness.py <outprefix> <mode> <target> <cols> <rows> <script.json> [extra args]
script: list of steps:
  {"send": {...}|"raw line"} | {"sleep": s} | {"close_stdin": true} | {"kill": true}
  {"wait_frame_with": "text", "timeout": s}   (searches frames received since the last send)
Writes <outprefix>.stdout.ndjson (raw stdout), <outprefix>.stdin.ndjson, <outprefix>.timeline.ndjson
"""
import sys, json, subprocess, threading, time, base64

out, mode, target, cols, rows, script = sys.argv[1:7]
extra = sys.argv[7:]
steps = json.load(open(script))
cmd = ["herdr", "terminal", "session", mode, target, "--cols", cols, "--rows", rows] + extra
t0 = time.monotonic()
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, bufsize=0)
tl = open(out + ".timeline.ndjson", "w")
so = open(out + ".stdout.ndjson", "wb")
si = open(out + ".stdin.ndjson", "w")
fx = open(out + ".transcript.ndjson", "w")


def fxw(d, line):
    fx.write(json.dumps({"t_ms": round((time.monotonic() - t0) * 1000, 1), "dir": d, "line": line}, ensure_ascii=False) + "\n")
    fx.flush()

cond = threading.Condition()
frames = []
last_send_idx = 0


def ev(kind, **kw):
    kw.update(t=round((time.monotonic() - t0) * 1000, 2), kind=kind)
    tl.write(json.dumps(kw, ensure_ascii=False) + "\n")
    tl.flush()


import os
READ_BPS = float(os.environ.get("READ_BPS", "0"))


def reader():
    for line in p.stdout:
        if READ_BPS:
            time.sleep(len(line) / READ_BPS)
        so.write(line)
        so.flush()
        with cond:
            fxw("stdout", line.decode("utf-8", "replace").rstrip("\n"))
        try:
            j = json.loads(line)
        except Exception:
            with cond:
                ev("stdout_raw", raw=line.decode(errors="replace"))
            continue
        info = {k: v for k, v in j.items() if k != "bytes"}
        if "bytes" in j:
            b = base64.b64decode(j["bytes"])
            info["nbytes"] = len(b)
            info["line_len"] = len(line)
            info["text"] = b.decode("utf-8", "replace")
        with cond:
            ev("recv", **info)
            frames.append(info)
            cond.notify_all()
    with cond:
        ev("stdout_eof")
        fxw("stdout_eof", None)
        cond.notify_all()


def errreader():
    for line in p.stderr:
        with cond:
            ev("stderr", line=line.decode(errors="replace").rstrip())
            fxw("stderr", line.decode(errors="replace").rstrip())


threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=errreader, daemon=True).start()
for st in steps:
    if "sleep" in st:
        time.sleep(st["sleep"])
    elif "send" in st:
        line = (st["send"] if isinstance(st["send"], str) else json.dumps(st["send"], ensure_ascii=False)) + "\n"
        with cond:
            last_send_idx = len(frames)
            ev("send", line=line.rstrip("\n"))
            fxw("stdin", line.rstrip("\n"))
        si.write(line)
        si.flush()
        try:
            p.stdin.write(line.encode())
            p.stdin.flush()
        except (BrokenPipeError, ValueError):
            with cond:
                ev("broken_pipe")
    elif "close_stdin" in st:
        with cond:
            ev("close_stdin")
            fxw("stdin_eof", None)
        p.stdin.close()
    elif "kill" in st:
        with cond:
            ev("kill")
            fxw("sigkill", None)
        p.kill()
    elif "wait_frame_with" in st:
        needle = st["wait_frame_with"]
        deadline = time.monotonic() + st.get("timeout", 5)
        with cond:
            while not any(needle in f.get("text", "") for f in frames[last_send_idx:]):
                rem = deadline - time.monotonic()
                if rem <= 0:
                    ev("wait_timeout", needle=needle)
                    break
                cond.wait(rem)
try:
    rc = p.wait(timeout=st.get("final_wait", 10) if steps else 10)
except subprocess.TimeoutExpired:
    with cond:
        ev("still_running_killing")
    p.kill()
    rc = p.wait()
time.sleep(0.3)
with cond:
    ev("exit", rc=rc)
    fxw("exit", rc)
