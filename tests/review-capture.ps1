param(
    [string]$Output = 'C:\Work\gemini-input\shots',
    [ValidateSet('hub','ar','hub-current','hub-pro','warehouse-normal')][string]$Scenario = 'hub',
    [string]$DataRoot = ''
)
$ErrorActionPreference = 'Stop'
if (!$Output) { $Output = if ($Scenario -eq 'h3') { 'C:\Work\gemini-input\p3\evidence\h3\review-' + [guid]::NewGuid().ToString('N').Substring(0,8) } else { 'C:\Work\gemini-input\shots' } }
$app = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox\craftos-2.8.3'
if (!$DataRoot) { $DataRoot = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox' }
$viewScenario = $Scenario -in @('hub-current','hub-pro','warehouse-normal')
if ($viewScenario) {
    $run = Join-Path 'C:\Work\gemini-input\p2\evidence\pr5\captures' ($Scenario + '-' + [guid]::NewGuid().ToString('N'))
} else {
    $run = Join-Path $DataRoot ('review-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Force "$run\config", "$run\computer\0", $Output | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$run\config\global.json", '{"standardsMode":true,"computerSpaceLimit":4000000,"checkUpdates":false,"keepOpenOnShutdown":false,"useHardwareRenderer":false,"useWebP":false}', $utf8)
if ($Scenario -eq 'ar') {
    [IO.File]::WriteAllText("$run\config\global.json", '{"standardsMode":true,"computerSpaceLimit":4000000,"checkUpdates":false,"keepOpenOnShutdown":false,"useHardwareRenderer":false,"useWebP":false,"defaultWidth":85,"defaultHeight":32}', $utf8)
}
if ($viewScenario) {
    foreach ($file in Get-ChildItem "$PSScriptRoot\..\*.lua") {
        Copy-Item -LiteralPath $file.FullName -Destination "$run\computer\0"
    }
    Copy-Item -LiteralPath "$PSScriptRoot\review-capture-hub.lua" -Destination "$run\computer\0"
    Copy-Item -LiteralPath "$PSScriptRoot\review-capture-views.lua" -Destination "$run\computer\0"
    $startup = if ($Scenario -eq 'hub-current') { 'shell.run("review-capture-hub.lua")' } else {
        'local ok,e=pcall(assert(loadfile("review-capture-views.lua","t",_ENV)),"' + $Scenario + '"); if not ok then local f=fs.open("capture-error.txt","w");f.write(tostring(e));f.close() end'
    }
    [IO.File]::WriteAllText("$run\computer\0\startup.lua", $startup, $utf8)
} else {
    foreach ($name in @('hub.lua','miner.lua','update.lua','fleetview.lua')) {
        Copy-Item -LiteralPath "$PSScriptRoot\..\$name" -Destination "$run\computer\0"
    }
    Copy-Item -LiteralPath "$PSScriptRoot\review-capture-hub.lua" -Destination "$run\computer\0"
    if ($Scenario -eq 'ar') {
        New-Item -ItemType Directory -Force "$run\computer\0\tests" | Out-Null
        foreach ($name in @('ar-hud.lua','ssot.lua','atomic.lua','mine-tasks.lua','warehouse-tasks.lua')) {
            Copy-Item "$PSScriptRoot\..\$name" "$run\computer\0"
        }
        Copy-Item "$PSScriptRoot\review-capture-ar.lua" "$run\computer\0"
        Copy-Item "$PSScriptRoot\ar-fixture.lua", "$PSScriptRoot\mocks.lua" "$run\computer\0\tests"
    }
    [IO.File]::WriteAllText("$run\computer\0\startup.lua", "local ok,err=pcall(dofile,'review-capture-$Scenario.lua'); if not ok then local h=fs.open('capture-error.txt','w'); h.write(tostring(err)); h.close() end", $utf8)
}
$oldVideo = $env:SDL_VIDEODRIVER
$oldAudio = $env:SDL_AUDIODRIVER
try {
    $env:SDL_VIDEODRIVER = 'dummy'
    $env:SDL_AUDIODRIVER = 'dummy'
    $p = Start-Process -FilePath "$app\CraftOS-PC_console.exe" -ArgumentList "--gui --directory `"$run`" --rom `"$app`" --id 0" -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run\stdout.log" -RedirectStandardError "$run\stderr.log"
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $shot = Get-ChildItem -Path "$run\screenshots\*.png" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($shot -or $p.HasExited -or (Test-Path -LiteralPath "$run\computer\0\capture-error.txt")) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($shot -and !$p.HasExited) { $null = $p.WaitForExit(5000) }
    if (!$p.HasExited) { Stop-Process -Id $p.Id -Force }
    if (!$shot) {
        if (Test-Path "$run\computer\0\capture-error.txt") { Get-Content "$run\computer\0\capture-error.txt" | Write-Output }
        throw "No screenshot: $run"
    }
    if ($viewScenario) {
        Copy-Item -LiteralPath $shot.FullName -Destination "$Output\$Scenario.png" -Force
        New-Item -ItemType Directory -Force 'C:\Work\gemini-input\shots' | Out-Null
        Copy-Item -LiteralPath $shot.FullName -Destination "C:\Work\gemini-input\shots\$Scenario.png" -Force
        Get-ChildItem "$run\computer\0" -Filter 'capture-*.json' | Copy-Item -Destination $Output -Force
        Write-Output "$Output\$Scenario.png; actual CraftOS render; fixture and call logs $run"
    } else {
        Add-Type -AssemblyName System.Drawing
        $decoded = [System.Drawing.Image]::FromFile($shot.FullName)
        $decoded.Dispose()
        $name = if ($Scenario -eq 'ar') { 'ar-hud-emulated.png' } else { 'hub-current.png' }
        Copy-Item -LiteralPath $shot.FullName -Destination "$Output\$name"
        if ($Scenario -eq 'ar') { Copy-Item "$run\computer\0\ar-calls.json" $Output }
        Write-Output "$Output\$name (CraftOS-PC emulator)"
    }
} finally {
    if ($p -and !$p.HasExited) { Stop-Process -Id $p.Id -Force; $p.WaitForExit() }
    $env:SDL_VIDEODRIVER = $oldVideo
    $env:SDL_AUDIODRIVER = $oldAudio
}
