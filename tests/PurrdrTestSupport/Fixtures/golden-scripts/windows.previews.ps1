$marker=$a[0]
for($index=1;$index+4 -lt $a.Count;$index+=5){
$key=$a[$index];$kind=$a[$index+1];$knownVersion=$a[$index+4]
PWrite "$marker $key`n"
$handle=$null
try{
$file=PFind $kind $a[$index+2] $a[$index+3]
$handle=POpen $file
$size=$handle.Length;$version="$([IO.File]::GetLastWriteTimeUtc($file).Ticks)-$size $(PAnchor $handle $size)";$range='whole'
if($knownVersion){
$knownStamp=$knownVersion.Split([char]' ')[0];[long]$knownSize=-1
if(-not [long]::TryParse($knownStamp.Substring($knownStamp.LastIndexOf('-')+1),[ref]$knownSize)){$knownSize=-1}
if($knownVersion -ceq $version){$range='unchanged'}
elseif($knownSize -ge 0 -and $knownSize -lt $size -and ($size-$knownSize) -le 48000 -and "$knownStamp $(PAnchor $handle $knownSize)" -ceq $knownVersion -and ($knownSize -eq 0 -or (PRead $handle ($knownSize-1) 1)[0] -eq 10)){$range='appended'}
}
PWrite "$marker@ $key $range $version`n"
if($range -ceq 'appended'){$bytes=PRead $handle $knownSize ($size-$knownSize);PWrite ((($u.GetString($bytes) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n"}
elseif($range -ceq 'whole'){
if('pi','pipath','codex' -ccontains $kind){PWrite "$marker! $key`n";$header=PHead2 $file;PWrite ((($u.GetString($header) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n$marker $key`n"}
$start=[Math]::Max([long]0,$size-48000);$bytes=PRead $handle $start ($size-$start)
PWrite ((($u.GetString($bytes) -split "`n")|%{PStrip $_}) -join "`n");PWrite "`n"
}
}catch{}finally{if($handle){$handle.Close()}}
}
$o.Flush()