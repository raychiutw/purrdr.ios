"""接管、SSH client 被殺、observer 殘留。只對 w2(purrdr-spike)的 pane 操作。"""
import json, subprocess, sys, threading, time
from harness import run, summary, encoded, SSH

tag = sys.argv[1]
T = sys.argv[2] if len(sys.argv) > 2 else "w2:p1"
which = sys.argv[3:]
PS_PRE = "$ProgressPreference='SilentlyContinue'; "
REL = '{"type":"terminal.release"}'
# 只列出命令列含 "terminal session" 的 herdr.exe(都是本測試開的;使用者的 pane 不會用這個子指令)
LIST = encoded(PS_PRE + "Get-CimInstance Win32_Process -Filter \"Name='herdr.exe'\" | Where-Object { $_.CommandLine -like '*terminal session*' } | ForEach-Object { \"$($_.ProcessId) $($_.ParentProcessId) \" + ($_.CommandLine -replace '^.*herdr(\\.exe)?\"?\\s*','') }")


def procs(label):
    r = subprocess.run(SSH + [LIST], capture_output=True, text=True)
    print(f"  [procs {label}] {r.stdout.strip() or '(none)'} {r.stderr.strip()}")


def bg(name, cmd, steps, timeout=40):
    res = {}
    def go():
        res["log"], res["code"] = run(name, cmd, steps, timeout=timeout)
    t = threading.Thread(target=go); t.start()
    return t, res


def takeover():
    ctl = lambda extra="": f"herdr terminal session control {T} --cols 40 --rows 12{extra}"
    # A 先接上並保持;O 觀察;B 不帶 --takeover 被拒;C 接管後 release
    ta, ra = bg(f"{tag}-sc-06-takeover-A", ctl(), [("wait_stdout", 1, 15), ("sleep", 12), ("send", '{"type":"terminal.input","text":"x"}'), ("sleep", 1), ("eof",)])
    time.sleep(3)
    to, ro = bg(f"{tag}-sc-06-takeover-observer", f"herdr terminal session observe {T} --cols 30 --rows 8", [("wait_stdout", 1, 15), ("sleep", 14), ("eof",)], timeout=6)
    time.sleep(3)
    tb, rb = bg(f"{tag}-sc-06-takeover-B", ctl(), [("sleep", 5)])
    tb.join()
    tc, rc = bg(f"{tag}-sc-06-takeover-C", ctl(" --takeover").replace("--cols 40 --rows 12", "--cols 50 --rows 14"),
                [("wait_stdout", 1, 15), ("sleep", 2), ("send", REL)])
    for t in (ta, tc, to):
        t.join()
    for n, r in (("A", ra), ("observer", ro), ("B", rb), ("C", rc)):
        summary(f"{tag}-sc-06-takeover-{n}", r["log"], r["code"])
    procs("after takeover")


def kill_client(variant):
    cmd = f"herdr terminal session control {T} --cols 40 --rows 12"
    if variant == "ps":
        cmd = encoded(PS_PRE + f"& herdr terminal session control {T} --cols 40 --rows 12; exit $LASTEXITCODE")
    p = subprocess.Popen(SSH + [cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    first = p.stdout.readline()
    print(f"== kill-{variant}: first frame {len(first)} bytes")
    procs("while attached")
    p.kill(); p.wait()
    t0 = time.monotonic()
    for delay in (1, 4, 10):
        time.sleep(max(0, delay - (time.monotonic() - t0)))
        procs(f"+{delay}s after SIGKILL of local ssh")
        log, code = run(f"{tag}-sc-12-kill-{variant}-reattach-{delay}s", cmd, [("wait_stdout", 1, 10), ("send", REL)], timeout=15)
        summary(f"reattach +{delay}s", log, code)
        if any(e["dir"] == "stdout" and "terminal.frame" in (e["line"] or "") for e in log):
            break


def observe_linger():
    p = subprocess.Popen(SSH + [f"herdr terminal session observe {T} --cols 30 --rows 8"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.stdout.readline()
    print("== observe-linger: got first frame; closing local ssh")
    p.kill(); p.wait()
    for d in (2, 8):
        time.sleep(d if d == 2 else 6)
        procs(f"observer +{d}s")


for w in which:
    {"takeover": takeover, "kill-gb": lambda: kill_client("gb"), "kill-ps": lambda: kill_client("ps"),
     "observe-linger": observe_linger, "procs": lambda: procs("now")}[w]()
