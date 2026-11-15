import json, os

os.makedirs("fx", exist_ok=True)


def inp(t):
    return {"send": {"type": "terminal.input", "text": t}}


def inb(b64):
    return {"send": {"type": "terminal.input", "bytes": b64}}


def scroll(direction, lines, source="wheel", col=0, row=0):
    return {"send": {"type": "terminal.scroll", "direction": direction, "lines": lines,
                     "source": source, "column": col, "row": row, "modifiers": 0}}


def mouse(action, col, row, button="left"):
    return {"send": {"type": "terminal.mouse", "action": action, "button": button,
                     "column": col, "row": row, "modifiers": 0}}


REL = {"send": {"type": "terminal.release"}}
W = lambda s: {"sleep": s}

S = {}
# 每個情境開始前另外跑 prep(清畫面 + 清 scrollback),確保首個 full frame 沒有個資
S["prep"] = [W(0.3), inp("clear; printf '\\033[3J'\r"), W(0.6), {"close_stdin": True}]
S["01-handshake-echo-release"] = [W(0.4), inp('echo hello-""world\r'), {"wait_frame_with": "hello-world"},
                                  W(0.4), REL, W(0.3)]
S["02-resize"] = [W(0.4), inp("stty size\r"), W(0.5),
                  {"send": {"type": "terminal.resize", "cols": 60, "rows": 15, "cell_width_px": 0, "cell_height_px": 0}},
                  W(0.5), inp("stty size\r"), W(0.5),
                  {"send": {"type": "terminal.resize", "cols": 30, "rows": 10}}, W(0.5),
                  inp("stty size\r"), W(0.5), REL, W(0.3)]
S["03-scroll-host-scrollback"] = [W(0.4), inp("seq 1 60\r"), W(0.6),
                                  scroll("up", 5), W(0.4), scroll("up", 3, "page_key"), W(0.4),
                                  scroll("down", 2), W(0.4),
                                  mouse("down", 3, 3), mouse("up", 3, 3), W(0.4),
                                  inp("#"), W(0.4), inb("FQ=="), W(0.4), REL, W(0.3)]
S["04-mouse-wheel-vim"] = [W(0.4), inp("seq 1 100 | vim -u NONE -N -c 'set mouse=a nu' -\r"), W(1.5),
                           scroll("down", 1, col=10, row=5), W(0.5),
                           scroll("down", 3, col=10, row=5), W(0.5),
                           mouse("down", 6, 4), mouse("up", 6, 4), W(0.5),
                           inp(":echo line('.') col('.')\r"), W(0.5),
                           mouse("down", 5, 2), mouse("drag", 6, 3), mouse("drag", 7, 6), mouse("up", 7, 6), W(0.5),
                           inb("Gw=="), W(0.3), inp(":q!\r"), W(0.6), inp("clear\r"), W(0.5), REL, W(0.3)]
S["05-alternate-scroll-less"] = [W(0.4), inp("seq 1 100 | less\r"), W(0.8),
                                 scroll("down", 3), W(0.5), scroll("down", 1), W(0.5), scroll("up", 1), W(0.5),
                                 scroll("down", 1, "page_key"), W(0.5),
                                 inp("q"), W(0.5), inp("clear\r"), W(0.5), REL, W(0.3)]
S["07-unicode-colors"] = [W(0.4),
                          inp("printf '\\033[1;31mred\\033[0m \\033[38;5;214morange\\033[0m \\033[4munder\\033[0m\\n'\r"), W(0.5),
                          inp("/usr/bin/python3 -c \"print('\\u4e2d\\u6587 \\U0001F431 e\\u0301 x')\"\r"), W(0.6),
                          inp("echo 中文輸入\r"), W(0.5),
                          inp("\u001b[200~echo pasted\u001b[201~"), W(0.4), inp("\r"), W(0.5), REL, W(0.3)]
S["08-burst-coalesce"] = [W(0.4), inp('seq 1 100000; echo SEQ""DONE\r'), {"wait_frame_with": "SEQDONE", "timeout": 20},
                          W(0.4), inp("clear\r"), W(0.5), REL, W(0.3)]
S["09-invalid-input-stderr"] = [W(0.4),
                                {"send": {"type": "terminal.resize", "cols": 0, "rows": 10}}, W(0.3),
                                {"send": {"type": "terminal.resize", "cols": 40}}, W(0.3),
                                {"send": "this is not json"}, W(0.3),
                                {"send": {"type": "terminal.bogus"}}, W(0.3),
                                {"send": {"type": "terminal.input", "text": "x", "bytes": "eA=="}}, W(0.3),
                                {"send": ""}, W(0.3),
                                inp("echo still-""alive\r"), W(0.5), REL, W(0.3)]
S["10-stdin-eof-release"] = [W(0.4), inp("echo bye\r"), W(0.5), {"close_stdin": True}, W(0.3)]
S["11-oversize-input-disconnect"] = [W(0.4), {"send": {"type": "terminal.input", "text": "z" * (1100 * 1024)}},
                                     W(1.5), inp("echo after\r"), W(0.5), {"close_stdin": True}]
S["12-sigkill-then-reattach"] = [W(0.4), inp("echo before-kill\r"), W(0.5), {"kill": True}]
S["13-not-found"] = [W(1.0), {"close_stdin": True}]
# takeover 組:A 先持有、O 觀察、B 未帶 --takeover 被拒、C 帶 --takeover 接管
S["06-takeover-A"] = [W(0.3), inp('echo A""OWNS\r'), W(3.5), inp("echo A-after\r"), W(1.5), {"close_stdin": True}]
S["06-takeover-B"] = [W(0.5), inp("echo B-rejected\r"), W(0.8), {"close_stdin": True}]
S["06-takeover-C"] = [W(0.5), inp('echo C""OWNS; stty size\r'), W(1.2), inp("clear\r"), W(0.4), REL, W(0.3)]
S["06-takeover-observer"] = [W(5.5), inp("echo observer-ignored\r"), W(0.4), {"close_stdin": True}, W(0.6), {"kill": True}]
S["14-exited-control"] = [W(0.6), inp("exit\r"), W(1.5), {"close_stdin": True}]
S["14-exited-observer"] = [W(3.0), {"kill": True}]
for k, v in S.items():
    json.dump(v, open(f"fx/{k}.script.json", "w"), ensure_ascii=False)
print("ok", len(S))
