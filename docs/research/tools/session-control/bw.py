import json, sys

ev = [json.loads(l) for l in open(sys.argv[1])]
sends = [e for e in ev if e["kind"] in ("send", "close_stdin")]
bounds = [(s["t"], s.get("line", "close")[:50]) for s in sends] + [(1e12, "end")]
for i in range(len(bounds) - 1):
    a, name = bounds[i]
    b = bounds[i + 1][0]
    fr = [e for e in ev if e["kind"] == "recv" and e.get("type") == "terminal.frame" and a <= e["t"] < b]
    if not fr:
        print(f"{name!r}: 0 frames in {b-a:.0f}ms")
        continue
    dur = (fr[-1]["t"] - fr[0]["t"]) / 1000 or 1e-9
    raw = sum(f["nbytes"] for f in fr)
    wire = sum(f["line_len"] for f in fr)
    gaps = [fr[k + 1]["t"] - fr[k]["t"] for k in range(len(fr) - 1)]
    full = sum(1 for f in fr if f["full"])
    print(f"{name!r}: frames={len(fr)} full={full} span={dur:.2f}s raw={raw}B wire={wire}B "
          f"overhead={wire/raw:.2f}x avg_frame_wire={wire/len(fr):.0f}B max_frame_wire={max(f['line_len'] for f in fr)} "
          f"rate_wire={wire/dur/1024:.1f}KiB/s fps={len(fr)/dur:.1f} min_gap={min(gaps) if gaps else 0:.1f}ms")
