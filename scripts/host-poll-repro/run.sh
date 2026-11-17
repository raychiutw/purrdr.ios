#!/bin/bash
# 主機並行輪詢的回歸工具(#86、#91)。以 swift:6.4.2-noble 容器編譯可攜核心並連真主機(macOS 上可直接 swift run)。
#
# 用法：
#   PURRDR_REPRO_HOST=user@host[:port] PURRDR_REPRO_KEY=<私鑰> PURRDR_REPRO_HOST_KEY=<主機公鑰檔> \
#     scripts/host-poll-repro/run.sh [次數]
# 主機公鑰檔：`ssh-keyscan -t ed25519 <host> > host.pub`。可另設 ROUNDS、SUBSCRIPTIONS、WORKERS、STEP_LIMIT、CANCEL_GRACE。
# 每次上限 HARNESS_LIMIT 秒(預設 180);超過代表連程序都結束不了，記為 HUNG。
# Windows 開發機：在 WSL 裡跑(Docker 在 WSL);容器連本機要用 Tailscale IP。
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
build=${BUILD_DIR:-$HOME/.cache/purrdr-host-poll-repro}
mkdir -p "$build"
runs=${1:-1}
limit=${HARNESS_LIMIT:-180}
name=purrdr-host-poll-repro

docker run --rm -v "$repo":/repo -v "$build":/build swift:6.4.2-noble \
  swift build --package-path /repo/scripts/host-poll-repro --scratch-path /build -c debug >/dev/null || exit 2

red=0
for i in $(seq 1 "$runs"); do
  echo "=== 第 $i 次"
  docker rm -f $name >/dev/null 2>&1
  docker run -d --name $name -v "$build":/build:ro \
    -v "$PURRDR_REPRO_KEY":/key:ro -v "$PURRDR_REPRO_HOST_KEY":/host.pub:ro \
    -e PURRDR_REPRO_HOST="$PURRDR_REPRO_HOST" -e PURRDR_REPRO_KEY=/key -e PURRDR_REPRO_HOST_KEY=/host.pub \
    -e ROUNDS="${ROUNDS:-1}" -e SUBSCRIPTIONS="${SUBSCRIPTIONS:-2}" -e WORKERS="${WORKERS:-4}" \
    -e STEP_LIMIT="${STEP_LIMIT:-45}" -e CANCEL_GRACE="${CANCEL_GRACE:-2}" \
    swift:6.4.2-noble /build/debug/host-poll-repro >/dev/null
  for _ in $(seq 1 "$limit"); do
    [ "$(docker inspect -f '{{.State.Running}}' $name)" = false ] && break
    sleep 1
  done
  docker logs $name 2>&1 | tr -d '\r'
  if [ "$(docker inspect -f '{{.State.Running}}' $name)" = true ]; then
    echo "HUNG(超過 $limit 秒程序仍未結束)"
    red=1
  elif [ "$(docker inspect -f '{{.State.ExitCode}}' $name)" != 0 ]; then
    red=1
  fi
  docker rm -f $name >/dev/null 2>&1
done
[ $red = 0 ] && echo "全部 GREEN" || echo "有 RED"
exit $red
