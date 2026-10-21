$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\turnon-loaded.ps1"

$state = @{ sent = (New-Object Collections.Generic.List[string]); loaded = $false; gaveLoaded = $false }

function Send-Rcon([string]$Command) {
    $state.sent.Add($Command)
    if ($Command -eq 'forceload add -4 -4 -4 -4') { $state.loaded = $true; return 'marked' }
    if ($Command -eq 'computercraft turn-on 0 1 2 3 4 6') { return 'Turned on 3/6 computers' }
    if ($Command -eq 'computercraft turn-on 0') {
        if ($state.gaveLoaded) { return 'Turned on 0/0 computers' }
        if ($state.loaded) { $state.gaveLoaded = $true; return 'Turned on 1/1 computers' }
        return 'Turned on 0/0 computers'
    }
    return 'ok'
}
function Rcon([string]$Command) {
    Register-GatebComputerPlace $Command
    if ($Command -match '(^| )computercraft turn-on ') {
        return Invoke-LoadedTurnOn $Command { param($Sent) Send-Rcon $Sent } -WaitSec 3
    }
    Send-Rcon $Command
}

$child = Join-Path $env:TEMP 'turnon-loaded-check-child.ps1'
Set-Content -LiteralPath $child -Encoding ASCII -Value @'
$ErrorActionPreference = 'Stop'
Rcon 'setblock -4 65 -4 computercraft:computer_advanced{ComputerId:0}' | Out-Null
Rcon 'execute in minecraft:the_nether run setblock 512 65 0 computercraft:computer_advanced{ComputerId:4}' | Out-Null
$reply = Rcon 'computercraft turn-on 0'
if ($reply -ne 'Turned on 1/1 computers') { throw "scenario kept $reply" }
$six = Rcon 'computercraft turn-on 0 1 2 3 4 6'
if ($six -ne 'Turned on 3/6 computers') { throw "already-on reply became $six" }
try {
    Rcon 'computercraft turn-on 0' | Out-Null
    throw 'a lasting 0/0 turn-on was returned'
} catch {
    if ($_.Exception.Message -match 'lasting 0/0') { throw }
    if ($_.Exception.Message -notmatch '0/0') { throw }
    if ($_.Exception.Message -notmatch '1/1') { throw }
}
'@
& $child

$place = $GatebComputerAt['0']
if (-not $place -or [int]$place.X -ne -4 -or [int]$place.Z -ne -4) { throw 'place was not recorded from the child script' }
$nether = $GatebComputerAt['4']
if (-not $nether -or $nether.Dim -ne 'minecraft:the_nether' -or [int]$nether.X -ne 512) { throw 'nether place was not recorded from the child script' }
if (-not ($state.sent -contains 'forceload add -4 -4 -4 -4')) { throw 'chunk was not force-loaded before turn-on' }
Write-Output 'PASS turn-on force-loads the computer chunk and rejects 0/0'
