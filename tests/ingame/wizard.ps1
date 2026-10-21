$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 1,3,4) { Set-DepthIdle $id }
    Copy-DepthProbe 2 'depth-result.lua'
    Copy-DepthProbe 2 'wizard-probe.lua'
    Set-DepthStartup 2 'wizard-probe.lua'
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    Rcon 'setblock 100 65 110 computercraft:computer_advanced{ComputerId:2}' | Out-Null
    $disk = "$TestRoot\world\computercraft\computer\2"
    Rcon 'computercraft turn-on 2' | Out-Null
    Wait-DepthFile "$disk\wizard-ready" 120
    Remove-Item "$disk\wizard-ready" -Force
    Rcon 'computercraft shutdown 2' | Out-Null
    Rcon 'computercraft turn-on 2' | Out-Null
    Wait-DepthFile "$disk\board.txt" 60
    Invoke-DepthShot 'board' 'board.png'
    Invoke-DepthShot 'wizard' 'wizard.png'
    Wait-DepthFile "$disk\wizard-ready" 120
    Remove-Item "$disk\wizard-ready" -Force
    Rcon 'computercraft shutdown 2' | Out-Null
    Rcon 'computercraft turn-on 2' | Out-Null
    $result = Read-DepthResult 2 120
    Add-DepthFailures $result $problems 'wizard'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'wizard' ($problems.Count -eq 0) ($problems -join "`n")
