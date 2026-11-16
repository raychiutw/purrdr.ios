import sys
from harness import run, summary, encoded

tag = sys.argv[1]  # 例如 s094 / s095,記在檔名上
PING = '{"id":"purrdr:ping","method":"ping","params":{}}'
PS_PRE = "$ProgressPreference='SilentlyContinue'; "
PS_DIRECT = encoded(PS_PRE + "& herdr remote-api-bridge; exit $LASTEXITCODE")
PS_START = encoded(PS_PRE + "$p = Start-Process -FilePath herdr -ArgumentList 'remote-api-bridge' -NoNewWindow -PassThru; $p.WaitForExit(); exit $p.ExitCode")
PS_NOSESSION = encoded(PS_PRE + "& herdr --session purrdr-nosuch remote-api-bridge; exit $LASTEXITCODE")
SUB = '{"id":"purrdr:events.subscribe","method":"events.subscribe","params":{"subscriptions":[{"type":"workspace.created"},{"type":"workspace.closed"}]}}'

cases = {
    "gb-status": ("herdr status server", [("eof",)]),
    "gb-check": ("herdr remote-api-bridge --check", [("eof",)]),
    "gb-ping-open": ("herdr remote-api-bridge", [("send", PING), ("wait_stdout", 1, 10), ("sleep", 0.5), ("eof",)]),
    "gb-ping-eof": ("herdr remote-api-bridge", [("send", PING), ("eof",)]),
    "gb-two-requests": ("herdr remote-api-bridge", [("send", PING + "\n" + PING.replace("ping\"", "ping2\"", 1)), ("sleep", 3), ("eof",)]),
    "gb-invalid-json": ("herdr remote-api-bridge", [("send", '{"id":"x","method":"ping","params":{1}}'), ("wait_stdout", 1, 10), ("eof",)]),
    "gb-no-session": ("herdr --session purrdr-nosuch remote-api-bridge", [("send", PING), ("sleep", 3), ("eof",)]),
    "gb-sub-open": ("herdr remote-api-bridge", [("send", SUB), ("sleep", 4), ("eof",)]),
    "gb-sub-eof": ("herdr remote-api-bridge", [("send", SUB), ("eof",)]),
    "ps-ping-open": (PS_DIRECT, [("send", PING), ("wait_stdout", 1, 15), ("sleep", 0.5), ("eof",)]),
    "ps-ping-eof": (PS_DIRECT, [("send", PING), ("eof",)]),
    "ps-start-ping-open": (PS_START, [("send", PING), ("wait_stdout", 1, 15), ("sleep", 0.5), ("eof",)]),
    "ps-no-session": (PS_NOSESSION, [("send", PING), ("sleep", 4), ("eof",)]),
    "ps-sub-open": (PS_DIRECT, [("send", SUB), ("sleep", 5), ("eof",)]),
    "ps-sub-eof": (PS_DIRECT, [("send", SUB), ("eof",)]),
    # 模擬 OpenSSH 預設 shell 是 cmd:由 cmd.exe 再呼叫 powershell(實機預設 shell 是 Git Bash,不改 sshd 設定)
    "cmd-ps-ping-open": ("cmd.exe //c " + PS_DIRECT, [("send", PING), ("wait_stdout", 1, 15), ("sleep", 0.5), ("eof",)]),
}
only = sys.argv[2:] or list(cases)
for name in only:
    cmd, steps = cases[name]
    log, code = run(f"{tag}-{name}", cmd, steps, timeout=25)
    summary(f"{tag}-{name}", log, code)
