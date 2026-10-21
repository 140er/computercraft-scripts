$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 2..4) { Set-DepthIdle $id }
    Copy-DepthProbe 1 'depth-result.lua'
    Copy-DepthProbe 1 'faults-probe.lua'
    Set-DepthStartup 1 'faults-probe.lua'
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    Rcon 'setblock 60 64 60 minecraft:stone' | Out-Null
    Rcon 'setblock 61 64 60 minecraft:stone' | Out-Null
    Rcon 'setblock 60 65 60 computercraft:turtle_advanced[facing=east]{ComputerId:1,Fuel:100}' | Out-Null
    Rcon 'computercraft turn-on 1' | Out-Null
    $disk = "$TestRoot\world\computercraft\computer\1"
    Wait-DepthFile "$disk\faults-ready" 90
    Rcon 'computercraft shutdown 1' | Out-Null
    Rcon 'computercraft turn-on 1' | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    while (-not (Test-Path "$disk\depth-result.json") -and [DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw 'Minecraft exited during faults.' }
        $need = "$disk\faults-need"
        $done = "$disk\faults-need.done"
        if ((Test-Path $need) -and -not (Test-Path $done)) {
            $action = (Get-Content $need -Raw).Trim()
            if ($action -eq 'modem-on') {
                Rcon 'data merge block 60 65 60 {RightUpgrade:"computercraft:wireless_modem_advanced"}' | Out-Null
            } elseif ($action -eq 'modem-off') {
                Rcon 'data remove block 60 65 60 RightUpgrade' | Out-Null
            } elseif ($action -eq 'charger-on') {
                Rcon 'setblock 59 65 60 superbwarfare:charging_station' | Out-Null
                Rcon 'item replace block 59 65 60 container.0 with minecraft:coal_block 64' | Out-Null
            } elseif ($action -eq 'charger-off') {
                Rcon 'setblock 59 65 60 minecraft:air' | Out-Null
            } else {
                $problems.Add("Unknown fault request $action")
            }
            [IO.File]::WriteAllText($done, $action, $utf8)
        }
        Start-Sleep -Milliseconds 300
    }
    $result = Read-DepthResult 1 30
    Add-DepthFailures $result $problems 'faults'
    Get-ChildItem $disk -Filter 'attempt-*' | Copy-Item -Destination $Output -Force
    Invoke-DepthShot 'crossing' 'faults.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'faults' ($problems.Count -eq 0) ($problems -join "`n")
