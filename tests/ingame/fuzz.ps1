$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 2..4) { Set-DepthIdle $id }
    Copy-DepthProbe 1 'depth-result.lua'
    Copy-DepthProbe 1 'fuzz-probe.lua'
    Set-DepthStartup 1 'fuzz-probe.lua'
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    Rcon 'setblock 16 65 16 computercraft:computer_advanced{ComputerId:1}' | Out-Null
    Rcon 'computercraft turn-on 1' | Out-Null
    $result = Read-DepthResult 1 180
    Add-DepthFailures $result $problems 'fuzz'
    Invoke-DepthShot 'crossing' 'fuzz.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'fuzz' ($problems.Count -eq 0) ($problems -join "`n")
