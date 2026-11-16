"""pane 內程式結束(exit)與按鍵延遲。只對 w2 的 pane。"""
import json, statistics, subprocess, sys, threading, time, base64
from harness import run, summary, SSH

tag, which = sys.argv[1], sys.argv[2]


def exited():
    T = "w2:p2"
    res = {}
    def obs():
        res["o"] = run(f"{tag}-sc-14-exited-observer", f"herdr terminal session observe {T} --cols 30 --rows 8", [("sleep", 12)], timeout=15)
    t = threading.Thread(target=obs); t.start()
    time.sleep(3)
    log, code = run(f"{tag}-sc-14-exited-control", f"herdr terminal session control {T} --cols 40 --rows 12",
                    [("wait_stdout", 1, 15), ("sleep", 0.5), ("send", json.dumps({"type": "terminal.input", "text": "exit\r"})), ("sleep", 4)], timeout=15)
    t.join()
    summary("control", log, code)
    summary("observer", *res["o"])


def latency():
    """一個字元 → 含該字元的 frame。經 SSH,含網路來回。"""
    T = "w2:p1"
    p = subprocess.Popen(SSH + [f"herdr terminal session control {T} --cols 40 --rows 12"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    p.stdout.readline()
    samples = []
    for i in range(40):
        ch = "abcdefghij"[i % 10]
        t0 = time.monotonic()
        p.stdin.write((json.dumps({"type": "terminal.input", "text": ch}) + "\n").encode()); p.stdin.flush()
        while True:
            m = json.loads(p.stdout.readline())
            if m.get("type") == "terminal.frame" and ch.encode() in base64.b64decode(m["bytes"]).replace(b"\x1b[", b""):
                samples.append((time.monotonic() - t0) * 1000); break
        time.sleep(0.15)
    # 清掉輸入行:Ctrl-C(PSReadLine 會放棄目前這行)
    p.stdin.write(b'{"type":"terminal.input","bytes":"Aw=="}\n{"type":"terminal.release"}\n'); p.stdin.flush()
    p.wait(timeout=10)
    s = sorted(samples)
    print(f"keystroke->frame n={len(s)} p50={statistics.median(s):.1f}ms p90={s[int(len(s)*0.9)-1]:.1f}ms min={s[0]:.1f} max={s[-1]:.1f}")
    r = subprocess.run(["ping", "-c", "10", "-q", SSH[-1].split("@")[-1]], capture_output=True, text=True)
    print(r.stdout.strip().splitlines()[-1])


{"exited": exited, "latency": latency}[which]()
