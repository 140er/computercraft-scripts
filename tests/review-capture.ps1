param(
    [string]$Output = 'C:\Work\gemini-input\shots',
    [ValidateSet('hub','wizard')][string]$Scenario = 'hub',
    [ValidateSet('queue','answer')][string]$View = 'queue',
    [ValidateRange(26,200)][int]$Width = 51,
    [ValidateRange(16,100)][int]$Height = 19,
    [ValidateRange(1000000,16000000)][int]$DiskLimit = 4000000,
    [string]$DataRoot = ''
)
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox\craftos-2.8.3'
$runBase = if ($DataRoot) { $DataRoot } else { Join-Path $env:LOCALAPPDATA 'computercraft-sandbox' }
$run = Join-Path $runBase ('review-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force "$run\config", "$run\computer\0", $Output | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$run\config\global.json", (@{standardsMode=$true; computerSpaceLimit=$DiskLimit; checkUpdates=$false; keepOpenOnShutdown=$false; useHardwareRenderer=$false; useWebP=$false; defaultWidth=$Width; defaultHeight=$Height} | ConvertTo-Json), $utf8)
$files = if ($Scenario -eq 'wizard') { @('atomic.lua','wh2-board.lua','wh2-wizard-adapter.lua','wh2-wizard.lua') } else { @('hub.lua','miner.lua','update.lua','fleetview.lua') }
foreach ($name in $files) {
    Copy-Item -LiteralPath "$PSScriptRoot\..\$name" -Destination "$run\computer\0"
}
Copy-Item -LiteralPath "$PSScriptRoot\review-capture-$Scenario.lua" -Destination "$run\computer\0"
[IO.File]::WriteAllText("$run\computer\0\startup.lua", ('shell.run("review-capture-' + $Scenario + '.lua", "' + $View + '")'), $utf8)
$staged = @(Get-ChildItem -LiteralPath "$run\computer\0" -File | ForEach-Object { @{name=$_.Name;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash} })
[IO.File]::WriteAllText("$run\source.json", (@{scenario=$Scenario;view=$View;width=$Width;height=$Height;diskLimit=$DiskLimit;files=$staged} | ConvertTo-Json -Depth 6), $utf8)
$oldVideo = $env:SDL_VIDEODRIVER
$oldAudio = $env:SDL_AUDIODRIVER
try {
    $env:SDL_VIDEODRIVER = 'dummy'
    $env:SDL_AUDIODRIVER = 'dummy'
    $p = Start-Process -FilePath "$app\CraftOS-PC_console.exe" -ArgumentList "--gui --directory $run --rom $app --id 0" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run\stdout.log" -RedirectStandardError "$run\stderr.log"
    $p.PriorityClass = 'High'
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $shot = Get-ChildItem -Path "$run\screenshots\*.png" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($shot -or $p.HasExited -or (Test-Path -LiteralPath "$run\computer\0\capture-error.txt")) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$p.HasExited) { Stop-Process -Id $p.Id -Force }
    Copy-Item -LiteralPath "$run\computer", "$run\config" -Destination $Output -Recurse -Force
    Copy-Item -LiteralPath "$run\stdout.log", "$run\stderr.log", "$run\source.json" -Destination $Output -Force
    if (!$shot) {
        $failure = if (Test-Path -LiteralPath "$run\computer\0\capture-error.txt") { Get-Content -LiteralPath "$run\computer\0\capture-error.txt" -Raw } else { 'No screenshot' }
        throw "$failure. Capture artifacts: $run"
    }
    Copy-Item -LiteralPath $shot.FullName -Destination "$Output\$Scenario-current.png"
    Write-Output "$Output\$Scenario-current.png (CraftOS fixture, disk limit $DiskLimit)"
} finally {
    $env:SDL_VIDEODRIVER = $oldVideo
    $env:SDL_AUDIODRIVER = $oldAudio
}
