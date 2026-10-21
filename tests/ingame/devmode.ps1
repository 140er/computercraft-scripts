$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 2..4) { Set-DepthIdle $id }
    Copy-DepthProbe 1 'depth-result.lua'
    Copy-DepthProbe 1 'devmode-probe.lua'
    Set-DepthStartup 1 'devmode-probe.lua'
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    Rcon 'setblock 40 65 40 computercraft:computer_advanced{ComputerId:1}' | Out-Null
    Rcon 'setblock 40 65 44 superbwarfare:charging_station' | Out-Null
    Rcon 'item replace block 40 65 44 container.0 with minecraft:coal_block 64' | Out-Null
    Rcon 'setblock 40 65 45 computercraft:turtle_advanced[facing=north]{ComputerId:17,Fuel:20}' | Out-Null
    Rcon 'computercraft turn-on 1' | Out-Null
    $result = Read-DepthResult 1 120
    Add-DepthFailures $result $problems 'devmode settings'
    $before = Rcon 'data get block 40 65 45'
    $beforeFuel = if ($before -match 'Fuel:\s*(\d+)') { [int]$Matches[1] } else { -1 }
    Start-Sleep -Seconds 8
    Stop-TestServer
    Start-TestServer 'restart'
    Rcon 'forceload add 64 64 240 160' | Out-Null
    $after = Rcon 'data get block 40 65 45'
    $afterFuel = if ($after -match 'Fuel:\s*(\d+)') { [int]$Matches[1] } else { -1 }
    [IO.File]::WriteAllText("$Output\devmode-fuel.txt", "before=$beforeFuel`nafter=$afterFuel`n", $utf8)
    if ($afterFuel -le $beforeFuel) {
        $problems.Add("Live auto-charge did not raise fuel. Before $beforeFuel after $afterFuel. No startup reflash and no local drop-off config.")
    }
    Invoke-DepthShot 'crossing' 'devmode.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'devmode' ($problems.Count -eq 0) ($problems -join "`n")
