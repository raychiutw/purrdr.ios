i=$1
g=
for d in "${PI_CODING_AGENT_SESSION_DIR:-}" "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions" "$HOME/${PI_CONFIG_DIR:-.omp}/agent/sessions" "$HOME/${PI_CONFIG_DIR:-.omp}/agent/profiles" "${XDG_DATA_HOME:+$XDG_DATA_HOME/omp}"; do
if [ -n "$d" ] && [ -d "$d" ]; then
r=$(find "$d" -maxdepth 4 -type f \( -name "*_$i.jsonl" -o -name "$i.jsonl" \) -print 2>/dev/null)
if [ -n "$r" ]; then g="$g$r
"; fi
fi
done
g=$(printf '%s' "$g" | sort -u)
if [ -z "$g" ]; then exit 3; fi
k=$(printf '%s\n' "$g" | wc -l)
if [ $((k + 0)) -gt 1 ]; then exit 6; fi
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