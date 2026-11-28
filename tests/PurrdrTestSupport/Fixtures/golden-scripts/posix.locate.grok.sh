i=$1
h=${GROK_HOME:-$HOME/.grok}/sessions
if [ ! -d "$h" ]; then exit 3; fi
if [ ! -x "$h" ]; then exit 4; fi
g=$(find "$h" -mindepth 2 -maxdepth 2 -type d -name "$i" -print 2>/dev/null)
if [ -z "$g" ]; then exit 3; fi
k=$(printf '%s\n' "$g" | wc -l)
if [ $((k + 0)) -gt 1 ]; then exit 6; fi
f="$g/updates.jsonl"
d=${f%/*}
if [ ! -d "$d" ]; then exit 3; fi
if [ ! -x "$d" ]; then exit 4; fi
if [ ! -e "$f" ]; then exit 3; fi
if [ ! -r "$f" ]; then exit 5; fi
z=$(wc -c < "$f")
z=$((z + 0))
printf '%s\n%s\n' "$f" "$z"