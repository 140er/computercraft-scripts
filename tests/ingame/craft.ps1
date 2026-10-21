$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 2..4) { Set-DepthIdle $id }
    Copy-DepthProbe 1 'depth-result.lua'
    Copy-DepthProbe 1 'craft-probe.lua'
    Set-DepthStartup 1 'craft-probe.lua'
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    Rcon 'setblock 70 65 70 computercraft:computer_advanced{ComputerId:1}' | Out-Null
    Rcon 'setblock 70 65 72 minecraft:chest' | Out-Null
    Rcon 'computercraft turn-on 1' | Out-Null
    $disk = "$TestRoot\world\computercraft\computer\1"
    $which = Wait-DepthEither "$disk\craft-ready" "$disk\depth-result.json" 180
    if ($which -eq 'first') {
        Stop-TestServer
        Start-TestServer 'restart'
        Rcon 'forceload add 64 64 240 160' | Out-Null
        Rcon 'computercraft turn-on 1' | Out-Null
    }
    $result = Read-DepthResult 1 180
    Add-DepthFailures $result $problems 'craft'
    $expected = 32
    $expectedFile = "$TestRoot\world\computercraft\computer\1\expected-panes.txt"
    if (Test-Path $expectedFile) { $expected = [int](Get-Content $expectedFile -Raw).Trim() }
    $actual = Get-DepthCount '70 65 72' 'minecraft:red_stained_glass_pane'
    if ($actual -ne $expected) {
        $problems.Add("Output chest has $actual red stained glass panes. Expected $expected.")
    }
    Invoke-DepthShot 'crossing' 'craft.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'craft' ($problems.Count -eq 0) ($problems -join "`n")
