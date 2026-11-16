"""terminal session control/observe 實測。只對自建的 w2:p1(purrdr-spike)操作。"""
import base64, json, sys, threading, time, subprocess
from harness import run, summary, encoded, SSH

tag = sys.argv[1]
T = "w2:p1"
PS_PRE = "$ProgressPreference='SilentlyContinue'; "


def gb(args):
    return f"herdr terminal session {args}"


def ps(args):
    return encoded(PS_PRE + f"& herdr terminal session {args}; exit $LASTEXITCODE")


def inp(text):
    return json.dumps({"type": "terminal.input", "text": text})


def resize(c, r):
    return json.dumps({"type": "terminal.resize", "cols": c, "rows": r, "cell_width_px": 0, "cell_height_px": 0})


REL = '{"type":"terminal.release"}'
W = ("sleep", 1.5)
ECHO = inp("Write-Output ('hello-' + 'world')\r")


def cases():
    return {
        "01-handshake-echo-release": (gb(f"control {T} --cols 40 --rows 12"),
                                      [("wait_stdout", 1, 15), ("sleep", 0.5), ("send", ECHO), W, ("send", REL)]),
        "01ps-handshake-echo-release": (ps(f"control {T} --cols 40 --rows 12"),
                                        [("wait_stdout", 1, 15), ("sleep", 0.5), ("send", ECHO), W, ("send", REL)]),
        "02-resize": (gb(f"control {T} --cols 40 --rows 12"),
                      [("wait_stdout", 1, 15), ("send", inp("$Host.UI.RawUI.WindowSize\r")), W,
                       ("send", resize(60, 15)), ("sleep", 0.8), ("send", inp("$Host.UI.RawUI.WindowSize\r")), W,
                       ("send", resize(30, 10)), ("sleep", 0.8), ("send", inp("$Host.UI.RawUI.WindowSize\r")), W,
                       ("send", REL)]),
        "07-unicode-colors": (gb(f"control {T} --cols 40 --rows 12"),
                              [("wait_stdout", 1, 15), ("send", inp("cls\r")), ("sleep", 1),
                               ("send", inp('Write-Host red -ForegroundColor Red; Write-Output "中文 e$([char]0x301) $([char]::ConvertFromUtf32(0x1F642))"\r')),
                               ("sleep", 2), ("send", REL)]),
        "09-invalid-input-stderr": (gb(f"control {T} --cols 40 --rows 12"),
                                    [("wait_stdout", 1, 15),
                                     ("send", '{"type":"terminal.resize","cols":0,"rows":10}'),
                                     ("send", "this is not json"),
                                     ("send", '{"type":"terminal.bogus"}'),
                                     ("send", '{"type":"terminal.input","text":"x","bytes":"eA=="}'),
                                     ("send", inp("Write-Output still-alive\r")), W, ("send", REL)]),
        "10-stdin-eof-release": (gb(f"control {T} --cols 40 --rows 12"), [("wait_stdout", 1, 15), ("sleep", 0.5), ("eof",)]),
        "10ps-stdin-eof-release": (ps(f"control {T} --cols 40 --rows 12"), [("wait_stdout", 1, 15), ("sleep", 0.5), ("eof",)]),
        "13-not-found-control": (gb("control w9:p9 --cols 40 --rows 12"), [("sleep", 4)]),
        "13ps-not-found-control": (ps("control w9:p9 --cols 40 --rows 12"), [("sleep", 5)]),
        "13-not-found-observe": (gb("observe w9:p9 --cols 40 --rows 12"), [("sleep", 4)]),
        "03-scroll-mouse-shell": (gb(f"control {T} --cols 40 --rows 12"),
                                  [("wait_stdout", 1, 15), ("send", inp("1..60\r")), W,
                                   ("send", '{"type":"terminal.scroll","direction":"up","lines":5,"source":"wheel","column":0,"row":0,"modifiers":0}'), ("sleep", 1),
                                   ("send", '{"type":"terminal.mouse","action":"down","button":"left","column":3,"row":3,"modifiers":0}'),
                                   ("send", '{"type":"terminal.mouse","action":"up","button":"left","column":3,"row":3,"modifiers":0}'), ("sleep", 1),
                                   ("send", inp("cls\r")), W, ("send", REL)]),
    }


if __name__ == "__main__":
    cs = cases()
    for name in (sys.argv[2:] or list(cs)):
        cmd, steps = cs[name]
        log, code = run(f"{tag}-sc-{name}", cmd, steps, timeout=25)
        summary(f"{tag}-sc-{name}", log, code)
