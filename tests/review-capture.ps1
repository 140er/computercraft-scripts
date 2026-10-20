param([string]$Output = 'C:\Work\gemini-input\shots',
    [ValidateSet('hub-current','hub-pro','warehouse-normal')][string]$Scenario = 'hub-current')
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox\craftos-2.8.3'
$run = Join-Path 'C:\Work\gemini-input\p2\evidence\pr5\captures' ($Scenario + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force "$run\config", "$run\computer\0", $Output | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$run\config\global.json", '{"standardsMode":true,"computerSpaceLimit":4000000,"checkUpdates":false,"keepOpenOnShutdown":false,"useHardwareRenderer":false,"useWebP":false}', $utf8)
foreach ($file in Get-ChildItem "$PSScriptRoot\..\*.lua") {
    Copy-Item -LiteralPath $file.FullName -Destination "$run\computer\0"
}
Copy-Item -LiteralPath "$PSScriptRoot\review-capture-hub.lua" -Destination "$run\computer\0"
Copy-Item -LiteralPath "$PSScriptRoot\review-capture-views.lua" -Destination "$run\computer\0"
$startup = if ($Scenario -eq 'hub-current') { 'shell.run("review-capture-hub.lua")' } else {
    'local ok,e=pcall(assert(loadfile("review-capture-views.lua","t",_ENV)),"' + $Scenario + '"); if not ok then local f=fs.open("capture-error.txt","w");f.write(tostring(e));f.close() end'
}
[IO.File]::WriteAllText("$run\computer\0\startup.lua", $startup, $utf8)
$oldVideo = $env:SDL_VIDEODRIVER
$oldAudio = $env:SDL_AUDIODRIVER
try {
    $env:SDL_VIDEODRIVER = 'dummy'
    $env:SDL_AUDIODRIVER = 'dummy'
    $p = Start-Process -FilePath "$app\CraftOS-PC_console.exe" -ArgumentList "--gui --directory $run --rom $app --id 0" -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $shot = Get-ChildItem -Path "$run\screenshots\*.png" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($shot -or $p.HasExited) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$p.HasExited) { Stop-Process -Id $p.Id -Force }
    if (!$shot) { throw "No screenshot: $run" }
    Copy-Item -LiteralPath $shot.FullName -Destination "$Output\$Scenario.png" -Force
    New-Item -ItemType Directory -Force 'C:\Work\gemini-input\shots' | Out-Null
    Copy-Item -LiteralPath $shot.FullName -Destination "C:\Work\gemini-input\shots\$Scenario.png" -Force
    Get-ChildItem "$run\computer\0" -Filter 'capture-*.json' | Copy-Item -Destination $Output -Force
    Write-Output "$Output\$Scenario.png; actual CraftOS render; fixture and call logs $run"
} finally {
    if ($p -and !$p.HasExited) { Stop-Process -Id $p.Id -Force; $p.WaitForExit() }
    $env:SDL_VIDEODRIVER = $oldVideo
    $env:SDL_AUDIODRIVER = $oldAudio
}
