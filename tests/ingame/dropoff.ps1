$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 2..4) { Set-DepthIdle $id }
    Copy-DepthProbe 1 'depth-result.lua'
    Copy-DepthProbe 1 'dropoff-probe.lua'
    Set-DepthStartup 1 'dropoff-probe.lua'
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    Rcon 'setblock 50 65 50 minecraft:chest' | Out-Null
    Rcon 'setblock 50 65 51 computercraft:turtle_advanced[facing=north]{ComputerId:1,Fuel:1000}' | Out-Null
    foreach ($slot in 0..15) { Rcon "item replace block 50 65 51 container.$slot with minecraft:cobblestone 64" | Out-Null }
    $beforeTurtle = 0
    $beforeChest = Get-DepthCount '50 65 50' 'minecraft:cobblestone'
    Rcon 'computercraft turn-on 1' | Out-Null
    $result = Read-DepthResult 1 90
    Add-DepthFailures $result $problems 'dropoff'
    $afterChest = Get-DepthCount '50 65 50' 'minecraft:cobblestone'
    $afterText = Rcon 'data get block 50 65 51'
    if ($afterChest -le $beforeChest) {
        $problems.Add("Drop-off chest stayed at $beforeChest cobble. Turtle was full and has no local drop-off config. $afterText")
    }
    Invoke-DepthShot 'crossing' 'dropoff.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'dropoff' ($problems.Count -eq 0) ($problems -join "`n")
