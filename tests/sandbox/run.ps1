param(
    [ValidateRange(15, 3600)][int]$Seconds = 30,
    [string]$CraftOS = $env:CRAFTOS_PC,
    [string]$Source = (Resolve-Path "$PSScriptRoot\..\..").Path
)
$ErrorActionPreference = 'Stop'

try {
    $cache = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox'
    if (!$CraftOS) {
        $app = Join-Path $cache 'craftos-2.8.3'
        $CraftOS = Join-Path $app 'CraftOS-PC_console.exe'
        if (!(Test-Path -LiteralPath $CraftOS)) {
            New-Item -ItemType Directory -Force -Path $cache | Out-Null
            $zip = Join-Path $cache 'craftos-2.8.3.zip'
            $url = 'https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC-Portable-Win64.zip'
            Write-Output 'Downloading CraftOS-PC v2.8.3 portable...'
            Invoke-WebRequest -UseBasicParsing $url -OutFile $zip
            if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne 'caf74fa9d6fcce44c940bf77ff789378fa34a4ebb0b608c57f885a0b0aebac37') {
                throw 'CraftOS-PC archive checksum mismatch.'
            }
            Expand-Archive -LiteralPath $zip -DestinationPath $app -Force
        }
    }
    $CraftOS = (Resolve-Path -LiteralPath $CraftOS).Path
    $app = Split-Path $CraftOS
    if ((& $CraftOS --version | Select-Object -First 1) -ne 'CraftOS-PC v2.8.3') {
        throw 'Use CraftOS-PC v2.8.3 portable (CraftOS-PC_console.exe).'
    }
    $Source = (Resolve-Path -LiteralPath $Source).Path
    $run = Join-Path $cache ('runs\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path "$run\config" | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $config = @{
        standardsMode = $true; computerSpaceLimit = 1000000
        checkUpdates = $false; http_enable = $true; http_whitelist = @('*')
        keepOpenOnShutdown = $false; logErrors = $true
    } | ConvertTo-Json
    [IO.File]::WriteAllText("$run\config\global.json", $config, $utf8)
    $roles = @('server', 'hub', 'miner')
    for ($id = 0; $id -lt $roles.Count; $id++) {
        $disk = "$run\computer\$id"
        New-Item -ItemType Directory -Force -Path $disk | Out-Null
        # Copies, not mounts: repo scripts count towards each computer's disk limit.
        $files = if ($id -eq 0) { Get-ChildItem -LiteralPath $Source -Filter '*.lua' } else {
            Get-Item -LiteralPath "$Source\$($roles[$id]).lua", "$Source\miner.lua", "$Source\update.lua" | Sort-Object FullName -Unique
        }
        foreach ($file in $files) {
            # Match wget's LF text so a Windows checkout does not duplicate the HTTP cache.
            $code = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
            [IO.File]::WriteAllText("$disk\$($file.Name)", $code, $utf8)
        }
        Copy-Item -LiteralPath "$PSScriptRoot\driver.lua", "$PSScriptRoot\turtle.lua" -Destination $disk
        [IO.File]::WriteAllText("$disk\startup.lua", "shell.run('driver.lua', '$Seconds')", $utf8)
    }
    Write-Output "Sandbox: local source=$Source seconds=$Seconds standardsMode=true disk=1000000"
    Write-Output "Artifacts: $run"
    $arguments = '--headless --directory "{0}" --rom "{1}" --id 0' -f $run, $app
    $process = Start-Process -FilePath $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run\stdout.log" -RedirectStandardError "$run\stderr.log"
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds + 35)
    do {
        $complete = @(0..2 | Where-Object { Test-Path -LiteralPath "$run\computer\$_\sandbox-result.json" }).Count -eq 3
        if ($complete -or $process.HasExited) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $timedOut = !$complete -and !$process.HasExited
    $crashed = $process.HasExited
    # Keep computers alive until all reports exist: shutdown can strand sibling timers.
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
    $failed = $timedOut -or $crashed
    foreach ($id in 0..2) {
        $path = "$run\computer\$id\sandbox-result.json"
        if (!(Test-Path -LiteralPath $path)) {
            Write-Output "$($roles[$id]): FAIL booted=unknown errors=missing result (crash or timeout)"
            $failed = $true
            continue
        }
        $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $status = if ($result.ok) { 'PASS' } else { 'FAIL' }
        Write-Output "$($roles[$id]): $status booted=$($result.booted) errors=$(@($result.errors).Count) disk_free=$($result.free) rx=$($result.rx) http_ok=$($result.httpOK)/$($result.httpAttempts)"
        foreach ($line in $result.lines) { Write-Output "  last: $line" }
        foreach ($errorText in $result.errors) { Write-Output "  error: $errorText" }
        if (!$result.ok) { $failed = $true }
    }
    $stderr = Get-Content -LiteralPath "$run\stderr.log" -Raw
    if ($stderr) { Write-Output "Emulator stderr: $stderr"; $failed = $true }
    if ($timedOut) { Write-Output 'Emulator timed out.' }
    if ($crashed) { Write-Output "Emulator exited early: $($process.ExitCode)" }
    if ($failed) { Write-Output 'Sandbox FAIL'; exit 1 }
    Write-Output 'Sandbox PASS'
    exit 0
} catch {
    Write-Output "Sandbox FAIL: $($_.Exception.Message)"
    exit 1
}
