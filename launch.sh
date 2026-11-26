#!/bin/bash
# 用法: launch.sh <log 名> <plan> [tests 檔]
cd /tmp/trim
name=$1; plan=$2; file=${3:-tests.txt}
args=()
if [ "$plan" = Full ]; then
  while read -r t; do [ -n "$t" ] && args+=("-only-testing:PurrdrUITests/$t()"); done < "$file"
fi
exec /tmp/trim/run-ui.sh "$name" "$plan" "${args[@]}"
