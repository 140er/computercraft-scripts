param([string]$Computers,[string]$Output)
$ErrorActionPreference='Stop'
$source=(Resolve-Path "$PSScriptRoot\..\..").Path
$sha=[Security.Cryptography.SHA256]::Create()
$utf8=New-Object Text.UTF8Encoding($false)
function Hash-Text([string]$Path) {
    $text=[IO.File]::ReadAllText($Path).Replace("`r`n","`n")
    ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','').ToLowerInvariant()
}
$rows=@()
foreach($file in @('atomic.lua','ssot.lua','ssot-client.lua','mine-tasks.lua','nav.lua','mining.lua','miner.lua','server.lua','hub.lua','install.lua','update.lua')) {
    $hash=Hash-Text "$source\$file"
    foreach($id in @(0,1,2,3,4,6)) {
        if((Hash-Text "$Computers\$id\$file") -ne $hash){throw "Computer $id used a different $file."}
    }
    $rows+=@{file=$file;sha256=$hash;computers=@(0,1,2,3,4,6)}
}
$sha.Dispose()
$rows | ConvertTo-Json -Depth 4 | Set-Content "$Output\source-sha256.json"
Write-Output 'The six computer disks match the current production source after LF normalization.'
