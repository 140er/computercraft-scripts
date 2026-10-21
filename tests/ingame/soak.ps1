$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    Set-DepthIdle 0
    foreach ($id in 1..4) {
        Copy-DepthProbe $id 'depth-result.lua'
        Copy-DepthProbe $id 'soak-probe.lua'
        Set-DepthStartup $id 'soak-probe.lua'
    }
    Measure-DepthDisk $GateComputerSpaceLimit
    Start-DepthWorld
    foreach ($id in 1..4) {
        $x = 8 + ($id * 2)
        Rcon "setblock $x 65 8 computercraft:turtle_advanced[facing=north]{ComputerId:$id,Fuel:1000}" | Out-Null
    }
    Rcon 'computercraft turn-on 1 2 3 4' | Out-Null
    foreach ($id in 1..4) {
        $result = Read-DepthResult $id 7500
        Add-DepthFailures $result $problems "soak $id"
        $log = "$TestRoot\world\computercraft\computer\$id\soak-log.jsonl"
        if (Test-Path $log) { Copy-Item $log "$Output\soak-$id.jsonl" -Force }
        else { $problems.Add("Turtle $id wrote no soak log.") }
    }
    Invoke-DepthShot 'crossing' 'soak.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'soak' ($problems.Count -eq 0) ($problems -join "`n")
