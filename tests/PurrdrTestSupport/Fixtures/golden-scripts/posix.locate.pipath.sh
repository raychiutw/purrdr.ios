i=$1
f=$i
d=${f%/*}
if [ ! -d "$d" ]; then exit 3; fi
if [ ! -x "$d" ]; then exit 4; fi
if [ ! -e "$f" ]; then exit 3; fi
if [ ! -r "$f" ]; then exit 5; fi
z=$(wc -c < "$f")
z=$((z + 0))
printf '%s\n%s\n' "$f" "$z"
head -n 2 "$f"