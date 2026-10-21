param([string]$Computers,[string]$Output,[int[]]$Ids=@(0,1,2,3,4,6),[ValidateSet('ssot','nav','mining','warehouse')][string]$Scenario)
$ErrorActionPreference='Stop'
if (-not $Scenario) { throw 'verify-source needs -Scenario so each computer is checked against its own role.' }
$source=(Resolve-Path "$PSScriptRoot\..\..").Path
. "$PSScriptRoot\role-closure.ps1"
$sha=[Security.Cryptography.SHA256]::Create()
$utf8=New-Object Text.UTF8Encoding($false)
function Hash-Text([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing $Path" }
    $text=[IO.File]::ReadAllText($Path).Replace("`r`n","`n")
    ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','').ToLowerInvariant()
}
$rows=@()
foreach($id in $Ids) {
    $entries = Get-GateEntries $source $Scenario $id
    foreach($file in @(Get-GateRoleFiles -Source $source -Entry $entries)) {
        $disk = Join-Path (Join-Path $Computers "$id") ($file.DiskName -replace '/','\')
        $hash = Hash-Text $file.SourcePath
        if ((Hash-Text $disk) -ne $hash) { throw "Computer $id used a different $($file.DiskName)." }
        $rows += @{file=$file.DiskName;sha256=$hash;computer=$id}
    }
}
$sha.Dispose()
$rows | ConvertTo-Json -Depth 4 | Set-Content "$Output\source-sha256.json"
Write-Output 'The computer disks match the current production source after LF normalization.'
