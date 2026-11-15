"""把 fx/ 錄到的 transcript 匯出成 repo 用的 fixture,並檢查個資。
輸出每個情境三個檔:
  <name>.stdout.ndjson      herdr 原始 stdout(逐行原樣,可直接餵 parser)
  <name>.stdin.ndjson       我們送進 stdin 的行(超大輸入以摘要取代)
  <name>.transcript.ndjson  {"t_ms","dir","line"} 時間序,dir ∈ stdin/stdout/stderr/stdin_eof/stdout_eof/sigkill/exit
"""
import json, os, sys, base64, re, glob

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
# 個資檢查樣式:預設抓家目錄路徑;錄製時用 PII_PATTERN 加上自己的帳號、主機名等
BAD = re.compile(os.environ.get("PII_PATTERN", r"/Users/|/home/"), re.I)
problems = []
for path in sorted(glob.glob(os.path.join(src, "[0-9]*.transcript.ndjson"))):
    name = os.path.basename(path).replace(".transcript.ndjson", "")
    rows = [json.loads(l) for l in open(path)]
    out_lines, in_lines, tr = [], [], []
    for r in rows:
        line = r["line"]
        if r["dir"] == "stdin" and isinstance(line, str) and len(line) > 4096:
            j = json.loads(line)
            n = len(j["text"].encode())
            line = json.dumps({"type": "terminal.input", "text": "<省略:%d bytes 的 'z'>" % n}, ensure_ascii=False)
            r = dict(r, line=line, note="原始輸入為 %d bytes,fixture 以摘要取代" % n)
        if r["dir"] == "stdout":
            out_lines.append(line)
            j = json.loads(line)
            decoded = base64.b64decode(j["bytes"]).decode("utf-8", "replace") if "bytes" in j else line
            if BAD.search(decoded):
                problems.append((name, BAD.search(decoded).group(0)))
        elif r["dir"] == "stdin":
            in_lines.append(line)
            if BAD.search(line):
                problems.append((name, "stdin:" + BAD.search(line).group(0)))
        tr.append(r)
    open(os.path.join(dst, name + ".stdout.ndjson"), "w").write("".join(l + "\n" for l in out_lines))
    if in_lines:
        open(os.path.join(dst, name + ".stdin.ndjson"), "w").write("".join(l + "\n" for l in in_lines))
    open(os.path.join(dst, name + ".transcript.ndjson"), "w").write(
        "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in tr))
print("problems:", problems)
