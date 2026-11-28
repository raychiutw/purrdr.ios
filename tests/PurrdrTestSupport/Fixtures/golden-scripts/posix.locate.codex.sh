i=$1
h=${CODEX_HOME:-$HOME/.codex}
g=
z=
for d in "$h/sessions" "$h/archived_sessions"; do
if [ -d "$d" ]; then
if [ ! -x "$d" ]; then exit 4; fi
r=$(find "$d" -type f \( -name "rollout-*-$i.jsonl" -o -name "rollout-*-${i}_*.jsonl" \) -print 2>/dev/null)
if [ -n "$r" ]; then g="$g$r
"; fi
r=$(find "$d" -type f \( -name "rollout-*-$i.jsonl.zst" -o -name "rollout-*-${i}_*.jsonl.zst" \) -print 2>/dev/null)
if [ -n "$r" ]; then z=1; fi
fi
done
g=$(printf '%s' "$g" | sort -u)
if [ -z "$g" ]; then
if [ -n "$z" ]; then exit 7; fi
exit 3
fi
k=$(printf '%s\n' "$g" | wc -l)
if [ $((k + 0)) -gt 1 ]; then
w=$(find "$h" -maxdepth 1 -type f -name 'state_*.sqlite' -print 2>/dev/null | sort | while IFS= read -r s; do
q=$(sqlite3 -readonly "$s" "select rollout_path from threads where id = '$i';" 2>/dev/null | head -n 1)
if [ -n "$q" ] && printf '%s\n' "$g" | grep -F -x -q -e "$q"; then printf '%s\n' "$q"; break; fi
done)
if [ -z "$w" ]; then exit 6; fi
g=$w
fi
f=$g
d=${f%/*}
if [ ! -d "$d" ]; then exit 3; fi
if [ ! -x "$d" ]; then exit 4; fi
if [ ! -e "$f" ]; then exit 3; fi
if [ ! -r "$f" ]; then exit 5; fi
z=$(wc -c < "$f")
z=$((z + 0))
printf '%s\n%s\n' "$f" "$z"
head -n 2 "$f"