param([string]$Output = 'C:\Work\gemini-input\shots')
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox\craftos-2.8.3'
$run = Join-Path $env:LOCALAPPDATA ('computercraft-sandbox\review-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force "$run\config", "$run\computer\0", $Output | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$run\config\global.json", '{"standardsMode":true,"computerSpaceLimit":4000000,"checkUpdates":false,"keepOpenOnShutdown":false,"useHardwareRenderer":false,"useWebP":false}', $utf8)
foreach ($name in @('hub.lua','miner.lua','update.lua','fleetview.lua')) {
    Copy-Item -LiteralPath "$PSScriptRoot\..\$name" -Destination "$run\computer\0"
}
Copy-Item -LiteralPath "$PSScriptRoot\review-capture-hub.lua" -Destination "$run\computer\0"
[IO.File]::WriteAllText("$run\computer\0\startup.lua", 'shell.run("review-capture-hub.lua")', $utf8)
$oldVideo = $env:SDL_VIDEODRIVER
$oldAudio = $env:SDL_AUDIODRIVER
try {
    $env:SDL_VIDEODRIVER = 'dummy'
    $env:SDL_AUDIODRIVER = 'dummy'
    $p = Start-Process -FilePath "$app\CraftOS-PC_console.exe" -ArgumentList "--gui --directory $run --rom $app --id 0" -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $shot = Get-ChildItem -Path "$run\screenshots\*.png" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($shot -or $p.HasExited) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$p.HasExited) { Stop-Process -Id $p.Id -Force }
    if (!$shot) { throw "No screenshot: $run" }
    Copy-Item -LiteralPath $shot.FullName -Destination "$Output\hub-current.png"
    Write-Output "$Output\hub-current.png (existing hub, idle; no Pro Mode exists yet)"
} finally {
    $env:SDL_VIDEODRIVER = $oldVideo
    $env:SDL_AUDIODRIVER = $oldAudio
}
