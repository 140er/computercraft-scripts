$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 3,4) { Set-DepthIdle $id }
    foreach ($id in 1,2) {
        Copy-DepthProbe $id 'depth-result.lua'
        Copy-DepthProbe $id 'events-probe.lua'
        Set-DepthStartup $id 'events-probe.lua'
    }
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    Rcon 'setblock 20 65 20 computercraft:computer_advanced{ComputerId:1}' | Out-Null
    Rcon 'setblock 20 66 20 computercraft:wireless_modem_advanced[facing=down]' | Out-Null
    Rcon 'setblock 24 65 20 computercraft:computer_advanced{ComputerId:2}' | Out-Null
    Rcon 'setblock 24 66 20 computercraft:wireless_modem_advanced[facing=down]' | Out-Null
    Rcon 'computercraft turn-on 2' | Out-Null
    Start-Sleep -Seconds 2
    Rcon 'computercraft turn-on 1' | Out-Null
    $result = Read-DepthResult 1 90
    Add-DepthFailures $result $problems 'events'
    Invoke-DepthShot 'crossing' 'events.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'events' ($problems.Count -eq 0) ($problems -join "`n")
