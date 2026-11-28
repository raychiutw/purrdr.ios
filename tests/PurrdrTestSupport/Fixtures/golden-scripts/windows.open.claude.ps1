PRunBlock {
$c=Join-Path (PHome $env:CLAUDE_CONFIG_DIR '.claude') 'projects'
$f=PClaude $a[0] $a[1]
if(-not [IO.File]::Exists($f) -and [IO.Directory]::Exists($c)){$g=@(PList $c -Dir|%{Join-Path $_.FullName "$($a[0]).jsonl"}|?{[IO.File]::Exists($_)});if($g.Count -gt 0){$f=$g[0]}}
PWrite "$f`n"
$z=PProbe $f
PWrite "$z`n"
PWrite "purrdr-window`n"
$e=$z;$n=[int]$a[2];$c=[long]$a[3];$g=$true
if($c -le 0){$c=4194304;$g=$false}
try{$h=POpen $f}catch{PFail 5}
while($true){
$s=[Math]::Max([long]0,$e-$c);$st=New-Object Collections.Generic.List[long];$z=[long]0
if($e -gt $s){$b=PRead $h $s ($e-$s);$q=0;$known=($s -eq 0);$i=0;while($i -lt $b.Length){$j=[Array]::IndexOf($b,[byte]10,$i);if($j -lt 0){break};if($known){$st.Add($q)};$known=$true;$z=$j+1;$q=$j+1;$i=$j+1}}
if($st.Count -lt $n -and $s -gt 0 -and -not $g){$c=$c*4;continue}
$k=[Math]::Max(0,$st.Count-$n);if($st.Count -gt 0){$x=$s+$st[$k]}else{$x=$s+$z};$y=$s+$z
break
}
PWrite "$x $y`n"
if($y -gt $x){$b=PRead $h $x ($y-$x);PLines $b 0 $b.Length}
$h.Close()
}