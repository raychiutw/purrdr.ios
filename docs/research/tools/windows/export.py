"""把 Windows 實測(#6)的原始錄製去識別化後匯出成 fixture。

用法:PII_PATTERN='<帳號|主機名|專案名…>' REAL_USER=<帳號> REAL_HOST=<主機名> REAL_TERM_IDS='<term_…> <term_…>' \
      python3 -I export.py <raw 目錄> <repo 根目錄>

- 原始錄製由 harness.py 產生(raw/<名稱>.transcript.ndjson、.stdout、.stderr),不進 git。
- 取代表:帳號與家目錄、主機名、terminal id;超大輸入以摘要取代。
- 匯出後把 frame 的 base64 解開，連同所有文字以 PII_PATTERN 檢查，命中就中止。
"""
import base64, json, os, re, sys

raw_dir, repo = sys.argv[1], sys.argv[2]
pii = re.compile(os.environ["PII_PATTERN"], re.I)
user = os.environ.get("REAL_USER", "")
host = os.environ.get("REAL_HOST", "")
# REAL_TERM_IDS:測試 pane 的 terminal id(空白分隔),依序換成 term_0000000000d001、…d002
SUBS = [(t, f"term_0000000000d{i:03d}") for i, t in enumerate(os.environ.get("REAL_TERM_IDS", "").split(), 1)]
if host:
    SUBS.append((host, "DEMO-PC"))
if user:
    SUBS.append((user, "demo"))

DOCS = os.path.join(repo, "docs/research/fixtures/windows")
TESTS = os.path.join(repo, "tests/PurrdrTestSupport/Fixtures/herdr-0.9.5/windows")

# raw 名稱 → (匯出名稱, 是否也放進測試 bundle 的 stdout 檔名)
BRIDGE = {
    "gb-status": None, "gb-check": None, "gb-ping-open": "ping.ndjson", "gb-ping-eof": None,
    "gb-two-requests": None, "gb-invalid-json": "error.invalid-request.ndjson", "gb-no-session": None,
    "gb-sub-open": None, "gb-sub-eof": None,
    "ps-ping-open": "ping.powershell.ndjson", "ps-ping-eof": None, "ps-start-ping-open": None,
    "ps-no-session": None, "ps-sub-open": None, "ps-sub-eof": None, "cmd-ps-ping-open": None,
}
OTHER = {  # 只有 0.9.5
    "s095-sub-workspace-closed": ("bridge/0.9.5/sub-workspace-closed", "events.workspace-closed.ndjson"),
    "s095-utf8-gb": ("bridge/0.9.5/utf8-gb", None),
    "s095-utf8-ps": ("bridge/0.9.5/utf8-ps", None),
    "s095-utf8-pwsh": ("bridge/0.9.5/utf8-pwsh", None),
}
SC = ["01-handshake-echo-release", "01ps-handshake-echo-release", "02-resize", "03-scroll-mouse-shell",
      "06-takeover-A", "06-takeover-B", "06-takeover-C", "06-takeover-observer", "07-unicode-colors",
      "09-invalid-input-stderr", "10-stdin-eof-release", "10ps-stdin-eof-release", "11-oversize-input-disconnect",
      "12-kill-gb-reattach-1s", "12-kill-ps-reattach-1s", "13-not-found-control", "13ps-not-found-control",
      "13-not-found-observe", "14-exited-control", "14-exited-observer"]


def clean(text):
    for a, b in SUBS:
        text = text.replace(a, b)
    return text


def check(label, text):
    if pii.search(text):
        sys.exit(f"PII 命中:{label}: {pii.search(text).group(0)!r}")


def frames_text(stdout_text):
    out = []
    for line in stdout_text.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if isinstance(m, dict) and m.get("type") == "terminal.frame":
            out.append(base64.b64decode(m["bytes"]).decode("utf-8", "replace"))
    return "\n".join(out)


def export(raw_name, docs_name, test_stdout=None, stdout_test_dir=TESTS):
    base = os.path.join(raw_dir, raw_name)
    transcript = []
    stdin_lines = []
    for line in open(base + ".transcript.ndjson", encoding="utf-8"):
        e = json.loads(line)
        if e["dir"] == "stdin" and isinstance(e["line"], str) and len(e["line"]) > 4096:
            e["line"] = f"<省略:{len(e['line'])} bytes 的單則 terminal.input(text 為 'x' 重複)>"
        if e["dir"] == "stdin":
            stdin_lines.extend(e["line"].split("\n"))
        if isinstance(e["line"], str):
            e["line"] = clean(e["line"])
        transcript.append(json.dumps(e, ensure_ascii=False))
    stdout = clean(open(base + ".stdout", "rb").read().decode("utf-8"))
    stderr = clean(open(base + ".stderr", "rb").read().decode("utf-8"))
    files = {
        docs_name + ".transcript.ndjson": "\n".join(transcript) + "\n",
        docs_name + ".stdout.ndjson": stdout,
    }
    if stdin_lines:
        files[docs_name + ".stdin.ndjson"] = "\n".join(clean(s) for s in stdin_lines) + "\n"
    if stderr:
        files[docs_name + ".stderr.txt"] = stderr
    for name, content in files.items():
        check(name, content)
        if name.endswith(".stdout.ndjson"):
            check(name + "(frame bytes)", frames_text(content))
    for name, content in files.items():
        path = os.path.join(DOCS, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if content:
            open(path, "w", encoding="utf-8").write(content)
    if test_stdout:
        path = os.path.join(stdout_test_dir, test_stdout)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w", encoding="utf-8").write(stdout)
        if stderr and test_stdout.endswith(".stdout.ndjson"):
            open(path.replace(".stdout.ndjson", ".stderr.txt"), "w", encoding="utf-8").write(stderr)


for version in ("s094", "s095"):
    for raw, test_name in BRIDGE.items():
        export(f"{version}-{raw}", f"bridge/{version[1]}.{version[2]}.{version[3]}/{raw}",
               test_name if version == "s095" else None)
export("s094-sub-workspace-created", "bridge/0.9.4/sub-workspace-created")
for raw, (docs, test_name) in OTHER.items():
    export(raw, docs, test_name)
# 連不到 socket 的 stderr(Windows 的 Rust 錯誤格式、在地化的系統訊息)也放進測試 bundle
err = clean(open(os.path.join(raw_dir, "s095-gb-no-session.stderr"), "rb").read().decode("utf-8"))
check("no-session stderr", err)
open(os.path.join(TESTS, "error.server-not-running.stderr.txt"), "w", encoding="utf-8").write(err)
for name in SC:
    export(f"s095-sc-{name}", f"session-control/{name}", f"session-control/{name}.stdout.ndjson")
print("ok")
