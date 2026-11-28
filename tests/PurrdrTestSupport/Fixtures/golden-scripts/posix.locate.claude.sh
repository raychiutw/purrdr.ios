c=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
f="$c/projects/$2/$1.jsonl"
if [ ! -e "$f" ] && [ -d "$c/projects" ]; then
g=$(find "$c/projects" -mindepth 2 -maxdepth 2 -name "$1.jsonl" -print 2>/dev/null | head -n 1)
if [ -n "$g" ]; then f=$g; fi
fi
printf '%s\n' "$f"
d=${f%/*}
if [ ! -d "$d" ]; then exit 3; fi
if [ ! -x "$d" ]; then exit 4; fi
if [ ! -e "$f" ]; then exit 3; fi
if [ ! -r "$f" ]; then exit 5; fi
z=$(wc -c < "$f")
z=$((z + 0))
printf '%s\n' "$z"