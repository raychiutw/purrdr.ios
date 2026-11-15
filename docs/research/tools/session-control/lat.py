import json, re, sys, statistics as st

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x1b\x07]*(\x1b\\|\x07)")
ev = [json.loads(l) for l in open(sys.argv[1])]
lat = []
first = []
pend = None
for e in ev:
    if e["kind"] == "send":
        j = json.loads(e["line"])
        if j.get("type") == "terminal.input" and "text" in j and len(j["text"]) == 1:
            pend = (e["t"], j["text"]); gotfirst = False
        else:
            pend = None
    elif e["kind"] == "recv" and pend and e.get("type") == "terminal.frame":
        if not gotfirst:
            first.append(e["t"] - pend[0]); gotfirst = True
        if pend[1] in ANSI.sub("", e["text"]):
            lat.append(round(e["t"] - pend[0], 2)); pend = None


def summ(name, L):
    L2 = sorted(L)
    print(name, "n", len(L), "min", round(L2[0], 2), "p50", round(st.median(L), 2),
          "p90", round(L2[int(.9 * len(L))], 2), "p99/max", round(L2[-1], 2), "mean", round(st.mean(L), 2))


summ("first-frame", first)
summ("echo-visible", lat)
