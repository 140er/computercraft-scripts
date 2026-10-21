$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    $modules = @('atomic.lua','storage-ledger.lua','storage-peer.lua','ssot-hub.lua','s1_h4c.lua','s1_t1.lua','s1_i1.lua','s1_b1.lua')
    foreach ($id in 0..4) {
        $disk = "$TestRoot\world\computercraft\computer\$id"
        Get-ChildItem $disk -Force | Remove-Item -Recurse -Force
        New-Item -ItemType Directory -Force -Path $disk | Out-Null
        Set-DepthIdle $id
    }
    $disk = "$TestRoot\world\computercraft\computer\1"
    foreach ($name in $modules) { Copy-DepthText 1 $name (Join-Path $source $name) }
    Copy-DepthProbe 1 'depth-result.lua'
    Copy-DepthProbe 1 'disk1mb-probe.lua'
    Set-DepthStartup 1 'disk1mb-probe.lua'
    Set-DepthSpaceLimit 1000000
    Measure-DepthDisk 1000000
    Start-DepthWorld
    Rcon 'setblock 30 65 30 computercraft:computer_advanced{ComputerId:1}' | Out-Null
    Rcon 'computercraft turn-on 1' | Out-Null
    $first = Read-DepthResult 1 180
    Copy-Item "$disk\depth-result.json" "$Output\disk1mb-phase1.json" -Force
    if (Test-Path "$disk\disk-budget.json") { Copy-Item "$disk\disk-budget.json" "$Output\disk-budget.json" -Force }
    Add-DepthFailures $first $problems 'disk1mb'
    [IO.File]::WriteAllText("$disk\expected-capacity", "$GateComputerSpaceLimit", $utf8)
    [IO.File]::WriteAllText("$disk\disk-phase", "capacity", $utf8)
    Remove-Item "$disk\depth-result.json" -Force
    Set-DepthSpaceLimit $GateComputerSpaceLimit
    Stop-TestServer
    Start-TestServer 'capacity'
    Rcon 'forceload add 64 64 240 160' | Out-Null
    Rcon 'computercraft turn-on 1' | Out-Null
    $second = Read-DepthResult 1 120
    Copy-Item "$disk\depth-result.json" "$Output\disk1mb-phase2.json" -Force
    Add-DepthFailures $second $problems 'disk1mb capacity'
    Invoke-DepthShot 'crossing' 'disk1mb.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'disk1mb' ($problems.Count -eq 0) ($problems -join "`n")
