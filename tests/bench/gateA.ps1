param(
    [string]$Output,
    [string]$CraftOS = '',
    [int]$Seconds = 900,
    [int]$Disk = 1000000
)
$ErrorActionPreference = 'Stop'
if (!$Output) { throw 'The P0 probe requires an evidence output directory.' }
if (!$CraftOS) { $CraftOS = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox\craftos-2.8.3\CraftOS-PC_console.exe' }
$app = Split-Path $CraftOS
$run = Join-Path $Output ('sandbox-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force "$run\config" | Out-Null
& "$PSScriptRoot\prepare.ps1" -Computers "$run\computer"
$settings = @{
    standardsMode = $true
    computerSpaceLimit = $Disk
    checkUpdates = $false
    keepOpenOnShutdown = $false
    useHardwareRenderer = $false
    useWebP = $false
    http_enable = $true
    http_whitelist = @('*')
}
[IO.File]::WriteAllText("$run\config\global.json", ($settings | ConvertTo-Json))
$oldVideo, $oldAudio = $env:SDL_VIDEODRIVER, $env:SDL_AUDIODRIVER
$processes = @()
try {
    $env:SDL_VIDEODRIVER = 'dummy'
    $env:SDL_AUDIODRIVER = 'dummy'
    foreach ($id in 0..2) {
        $arguments = '--gui --directory "{0}" --rom "{1}" --id {2}' -f $run, $app, $id
        $process = Start-Process $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run\stdout-$id.log" -RedirectStandardError "$run\stderr-$id.log"
        $process.PriorityClass = 'High'
        $processes += $process
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $finished = @(0..2 | Where-Object { Test-Path "$run\computer\$_\initial-complete" }).Count -eq 3
        if ($finished -or @($processes | Where-Object HasExited).Count) { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    $summary = @{runtime='CraftOS-PC'; run=$run; complete=$finished; computers=3; mockTurtles=2; disk=$Disk; gpsHosts=0}
    $summary | ConvertTo-Json | Set-Content "$Output\gateA-run.json"
    if (!$finished) { throw "P0 sandbox did not finish. Evidence remains at $run" }
    foreach ($id in 0..2) {
        $initial = Get-Content "$run\computer\$id\results\initial.json" -Raw | ConvertFrom-Json
        if (!$initial.ok) { throw "Computer $id has a failed probe. Evidence remains at $run" }
    }
    Write-Output "P0 sandbox probes finished. Evidence at $run"
} finally {
    foreach ($process in $processes) {
        if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
    $env:SDL_VIDEODRIVER, $env:SDL_AUDIODRIVER = $oldVideo, $oldAudio
}
