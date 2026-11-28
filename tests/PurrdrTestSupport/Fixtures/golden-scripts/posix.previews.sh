m=$1
shift
while [ $# -ge 5 ]; do
printf '%s %s\n' "$m" "$1"
(
y=$1
t=$2
i=$3
p=$4
known_version=$5
case $t in
claude)
f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$p/$i.jsonl"
;;
grok)
h=${GROK_HOME:-$HOME/.grok}/sessions
if [ ! -d "$h" ]; then exit 3; fi
if [ ! -x "$h" ]; then exit 4; fi
g=$(find "$h" -mindepth 2 -maxdepth 2 -type d -name "$i" -print 2>/dev/null)
if [ -z "$g" ]; then exit 3; fi
k=$(printf '%s\n' "$g" | wc -l)
if [ $((k + 0)) -gt 1 ]; then exit 6; fi
f="$g/updates.jsonl"
;;
agy)
f="$HOME/.gemini/antigravity-cli/brain/$i/.system_generated/logs/transcript.jsonl"
;;
pi)
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
;;
codex)
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
;;
*)
f=$i
;;
esac
if [ -r "$f" ]; then
purrdr_anchor() {
if [ "$1" -le 0 ]; then anchor=0; return; fi
anchor_start=$(($1 - 64))
if [ "$anchor_start" -lt 0 ]; then anchor_start=0; fi
anchor=$(tail -c +$((anchor_start + 1)) "$f" | head -c $(($1 - anchor_start)) | cksum)
anchor=${anchor%% *}
}
size=$(wc -c < "$f")
size=$((size + 0))
purrdr_anchor "$size"
version="$(date -r "$f" +%s 2>/dev/null)-$size $anchor"
range=whole
if [ -n "$known_version" ]; then
known_size=${known_version%% *}
known_size=${known_size##*-}
case $known_size in
''|*[!0-9]*) known_size=-1 ;;
esac
if [ "$known_version" = "$version" ]; then
range=unchanged
elif [ "$known_size" -ge 0 ] && [ "$known_size" -lt "$size" ] && [ $((size - known_size)) -le 48000 ]; then
purrdr_anchor "$known_size"
if [ "$known_version" = "${known_version% *} $anchor" ] && { [ "$known_size" -eq 0 ] || [ "$(tail -c +"$known_size" "$f" | head -c 1 | wc -l)" -eq 1 ]; }; then range=appended; fi
fi
fi
printf '%s@ %s %s %s\n' "$m" "$y" "$range" "$version"
case $range in
appended)
tail -c +$((known_size + 1)) "$f" | head -c $((size - known_size)) | sed -e 's#"[A-Za-z0-9+/=]\{128,\}"#""#g' -e 's#"data:[^"]*;base64,[^"]*"#""#g'
printf '\n'
;;
whole)
case $t in
pi|pipath|codex)
printf '%s! %s\n' "$m" "$y"
head -n 2 "$f" | sed -e 's#"[A-Za-z0-9+/=]\{128,\}"#""#g' -e 's#"data:[^"]*;base64,[^"]*"#""#g'
printf '\n%s %s\n' "$m" "$y"
;;
esac
tail -c 48000 "$f" | sed -e 's#"[A-Za-z0-9+/=]\{128,\}"#""#g' -e 's#"data:[^"]*;base64,[^"]*"#""#g'
printf '\n'
;;
esac
fi
)
shift 5
done