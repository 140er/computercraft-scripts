$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\turnon-loaded.ps1"

function Invoke-FakeTurnOn([string]$Command, [scriptblock]$ReplyFor) {
    $script:sent = New-Object Collections.Generic.List[string]
    Invoke-LoadedTurnOn $Command {
        param($Sent)
        $script:sent.Add($Sent)
        & $ReplyFor $Sent
    } -WaitSec 3
}

Register-GatebComputerPlace 'setblock 503 65 512 computercraft:turtle_advanced{ComputerId:20,Fuel:100,RightUpgrade:"computercraft:wireless_modem_normal"}'
$loaded = $false
$reply = Invoke-FakeTurnOn 'computercraft turn-on 20' {
    param($Sent)
    if ($Sent -eq 'forceload add 503 512 503 512') { $script:loaded = $true }
    if ($Sent -eq 'computercraft turn-on 20') {
        if ($script:loaded) { return 'Turned on 1/1 computers' }
        return 'Turned on 0/0 computers'
    }
    return 'ok'
}
if ($reply -ne 'Turned on 1/1 computers') { throw "scenario kept $reply" }
if (-not ($script:sent -contains 'forceload add 503 512 503 512')) { throw 'chunk was not force-loaded before turn-on' }

$threw = $false
try {
    Invoke-FakeTurnOn 'computercraft turn-on 20' { param($Sent) 'Turned on 0/0 computers' } | Out-Null
} catch {
    $threw = $true
    if ($_.Exception.Message -notmatch '0/0') { throw }
    if ($_.Exception.Message -notmatch '1/1') { throw }
}
if (-not $threw) { throw 'a lasting 0/0 turn-on was returned' }

$six = Invoke-FakeTurnOn 'computercraft turn-on 0 1 2 3 4 6' { param($Sent) 'Turned on 3/6 computers' }
if ($six -ne 'Turned on 3/6 computers') { throw "already-on reply became $six" }
Write-Output 'PASS turn-on force-loads the computer chunk and rejects 0/0'
