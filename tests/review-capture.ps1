param(
    [string]$Output = 'C:\Work\gemini-input\shots',
    [ValidateSet('hub','ar')][string]$Scenario = 'hub',
    [string]$DataRoot = ''
)
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox\craftos-2.8.3'
if (!$DataRoot) { $DataRoot = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox' }
$run = Join-Path $DataRoot ('review-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force "$run\config", "$run\computer\0", $Output | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$run\config\global.json", '{"standardsMode":true,"computerSpaceLimit":4000000,"checkUpdates":false,"keepOpenOnShutdown":false,"useHardwareRenderer":false,"useWebP":false}', $utf8)
if ($Scenario -eq 'ar') {
    [IO.File]::WriteAllText("$run\config\global.json", '{"standardsMode":true,"computerSpaceLimit":4000000,"checkUpdates":false,"keepOpenOnShutdown":false,"useHardwareRenderer":false,"useWebP":false,"defaultWidth":85,"defaultHeight":32}', $utf8)
}
foreach ($name in @('hub.lua','miner.lua','update.lua','fleetview.lua')) {
    Copy-Item -LiteralPath "$PSScriptRoot\..\$name" -Destination "$run\computer\0"
}
Copy-Item -LiteralPath "$PSScriptRoot\review-capture-hub.lua" -Destination "$run\computer\0"
if ($Scenario -eq 'ar') {
    New-Item -ItemType Directory -Force "$run\computer\0\tests" | Out-Null
    Copy-Item "$PSScriptRoot\..\ar-hud.lua", "$PSScriptRoot\review-capture-ar.lua" "$run\computer\0"
    Copy-Item "$PSScriptRoot\ar-fixture.lua", "$PSScriptRoot\mocks.lua" "$run\computer\0\tests"
}
[IO.File]::WriteAllText("$run\computer\0\startup.lua", "local ok,err=pcall(dofile,'review-capture-$Scenario.lua'); if not ok then local h=fs.open('capture-error.txt','w'); h.write(tostring(err)); h.close() end", $utf8)
$oldVideo = $env:SDL_VIDEODRIVER
$oldAudio = $env:SDL_AUDIODRIVER
try {
    $env:SDL_VIDEODRIVER = 'dummy'
    $env:SDL_AUDIODRIVER = 'dummy'
    $p = Start-Process -FilePath "$app\CraftOS-PC_console.exe" -ArgumentList "--gui --directory `"$run`" --rom `"$app`" --id 0" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run\stdout.log" -RedirectStandardError "$run\stderr.log"
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $shot = Get-ChildItem -Path "$run\screenshots\*.png" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($shot -or $p.HasExited) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($shot -and !$p.HasExited) { $null = $p.WaitForExit(5000) }
    if (!$p.HasExited) { Stop-Process -Id $p.Id -Force }
    if (!$shot) {
        if (Test-Path "$run\computer\0\capture-error.txt") { Get-Content "$run\computer\0\capture-error.txt" | Write-Output }
        throw "No screenshot: $run"
    }
    Add-Type -AssemblyName System.Drawing
    $decoded = [System.Drawing.Image]::FromFile($shot.FullName)
    $decoded.Dispose()
    $name = if ($Scenario -eq 'ar') { 'ar-hud-emulated.png' } else { 'hub-current.png' }
    Copy-Item -LiteralPath $shot.FullName -Destination "$Output\$name"
    if ($Scenario -eq 'ar') { Copy-Item "$run\computer\0\ar-calls.json" $Output }
    Write-Output "$Output\$name (CraftOS-PC emulator)"
} finally {
    $env:SDL_VIDEODRIVER = $oldVideo
    $env:SDL_AUDIODRIVER = $oldAudio
}
