#!/bin/sh
# 印出某個 commit 的主機服務版本號(host-service/service/Cargo.toml 的 [package] version)。
# 用法:scripts/host-service-version.sh [commit](預設 HEAD)
# 主機服務 Release workflow 以它比對合併前後的版本號：有變才發行(#198)。
set -eu

commit="${1:-HEAD}"
manifest="host-service/service/Cargo.toml"

version="$(git show "$commit:$manifest" | awk '
  /^\[/ { in_package = ($0 == "[package]") }
  in_package && /^version[[:space:]]*=/ { gsub(/.*=[[:space:]]*"|".*/, ""); print; exit }
')"
if [ -z "$version" ]; then
  echo "$commit 的 $manifest 找不到 [package] version" >&2
  exit 1
fi
printf '%s\n' "$version"
