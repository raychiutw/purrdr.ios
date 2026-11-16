#!/bin/sh
# 從真實主機錄一份 herdr socket API 的回應，給假主機回放(tests/PurrdrTestSupport/Fixtures/)。
#
# 用法:
#   scripts/record-herdr-fixture.sh <fixture 檔名> <method> [params JSON] [ssh 目的地]
#
# 例:
#   scripts/record-herdr-fixture.sh session.snapshot.ndjson session.snapshot
#   scripts/record-herdr-fixture.sh session.snapshot.ndjson session.snapshot '{}' ray@my-mac
#
# 不給 ssh 目的地時在本機跑 `herdr remote-api-bridge`。stdin 送出一行請求後保持開著 2 秒
# (bridge 在 stdin EOF 時會放棄「需要等待」的請求，見行為規格 §3.3),只留第一行回應。
#
# 存檔前會把家目錄、使用者名稱與 session UUID 換成假值;workspace 名稱、終端機標題這類
# 個人內容腳本不會動，存檔後一定要自己打開檢查、改成假值(見 Fixtures/README.md)。
set -eu

if [ $# -lt 2 ]; then
    sed -n '2,15p' "$0"
    exit 64
fi

name="$1"
method="$2"
params="${3:-}"; [ -n "$params" ] || params="{}"
destination="${4:-}"
version="$(herdr --version | awk '{print $2}')"
out_dir="$(cd "$(dirname "$0")/.." && pwd)/tests/PurrdrTestSupport/Fixtures/herdr-$version"
mkdir -p "$out_dir"
raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT

request="{\"id\":\"purrdr:1\",\"method\":\"$method\",\"params\":$params}"
if [ -n "$destination" ]; then
    (printf '%s\n' "$request"; sleep 2) | ssh "$destination" 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" herdr remote-api-bridge' | head -n 1 > "$raw"
    remote_home="$(ssh "$destination" 'printf %s "$HOME"')"
    remote_user="$(ssh "$destination" 'id -un')"
else
    (printf '%s\n' "$request"; sleep 2) | herdr remote-api-bridge | head -n 1 > "$raw"
    remote_home="$HOME"
    remote_user="$(id -un)"
fi

python3 -I - "$raw" "$out_dir/$name" "$remote_home" "$remote_user" <<'PY'
import json, re, sys, uuid
raw, out, home, user = sys.argv[1:5]
text = open(raw, encoding="utf-8").read().strip()
text = text.replace(json.dumps(home)[1:-1], "/Users/demo").replace(home, "/Users/demo")
text = re.sub(r"\b%s\b" % re.escape(user), "demo", text)
fakes = {}
def fake(match):
    return fakes.setdefault(match.group(0), str(uuid.UUID(int=len(fakes) + 1)))
text = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", fake, text)
json.loads(text)  # 確認仍是合法 JSON
open(out, "w", encoding="utf-8").write(text + "\n")
PY

echo "已存到 ${out_dir}/${name}。請打開檢查並把 workspace 名稱、標題、資料夾換成假值。"
