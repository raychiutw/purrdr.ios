import base64, json, re, sys, collections
for path in sys.argv[1:]:
    print("##", path)
    csi = collections.Counter()
    for raw in open(path, "rb").read().split(b"\n"):
        if not raw.strip():
            continue
        m = json.loads(raw)
        if m["type"] != "terminal.frame":
            print("  ", m); continue
        b = base64.b64decode(m["bytes"])
        for s in re.findall(rb"\x1b\[\?[0-9;]*[a-zA-Z]|\x1b\][0-9]+;", b):
            csi[s] += 1
        text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x1b\x07]*(\x1b\\|\x07)", b" ", b).decode("utf-8", "replace")
        print(f"  seq={m['seq']} full={m['full']} {m['width']}x{m['height']} raw={len(b)} | {re.sub(' +',' ',text)[:160]}")
    print("  private/OSC seqs:", dict(csi))
