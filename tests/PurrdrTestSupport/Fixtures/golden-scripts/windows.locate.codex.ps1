PRunBlock {
$f=PFind 'codex' $a[0] ''
$z=PProbe $f
PWrite "$f`n$z`n"
$x=PHead2 $f;$o.Write($x,0,$x.Length)
}