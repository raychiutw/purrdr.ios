#!/bin/bash
# 依序錄製 fixture。只操作專用測試 pane(herdr workspace create --no-focus 建立)。
# 前置:先在該 pane 執行
#   exec env -i HOME=/tmp TERM=xterm-256color LANG=en_US.UTF-8 PS1='$ ' /bin/bash --norc --noprofile
# 讓 prompt 與畫面不含個資。最後的 14-exited 會結束該 pane。
set -u
cd "$(dirname "$0")"
T="${1:?用法: runfx.sh <terminal_id> <pane_id>}"
P="${2:?用法: runfx.sh <terminal_id> <pane_id>}"
python3 -I mkfx.py
H="python3 -I harness.py"
prep() { $H fx/_prep control $T 40 12 fx/prep.script.json; }
one() { prep; $H "fx/$1" control $T 40 12 "fx/$1.script.json" "${@:2}"; }

one 01-handshake-echo-release
one 02-resize
one 03-scroll-host-scrollback
one 04-mouse-wheel-vim
one 05-alternate-scroll-less
one 07-unicode-colors
one 08-burst-coalesce
one 09-invalid-input-stderr
one 10-stdin-eof-release
one 11-oversize-input-disconnect
one 12-sigkill-then-reattach
$H fx/12-sigkill-then-reattach-2 control $T 40 12 fx/10-stdin-eof-release.script.json
$H fx/13-not-found-control control term_doesnotexist 40 12 fx/13-not-found.script.json
$H fx/13-not-found-observe observe term_doesnotexist 40 12 fx/13-not-found.script.json

prep
$H fx/06-takeover-A control $T 40 12 fx/06-takeover-A.script.json &
sleep 0.15
$H fx/06-takeover-observer observe $T 30 8 fx/06-takeover-observer.script.json &
sleep 1.0
$H fx/06-takeover-B control $T 40 12 fx/06-takeover-B.script.json &
sleep 1.0
$H fx/06-takeover-C control $T 50 14 fx/06-takeover-C.script.json --takeover &
wait

# 14:observer 在旁觀察,control 用 pane id 當 target,送 exit 讓 terminal 結束
prep
$H fx/14-exited-observer observe $T 40 12 fx/14-exited-observer.script.json &
sleep 0.3
$H fx/14-exited-control control "$P" 40 12 fx/14-exited-control.script.json
wait
echo done
