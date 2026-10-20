param(
    [ValidateRange(15, 3600)][int]$Seconds = 30,
    [string]$CraftOS = $env:CRAFTOS_PC,
    [string]$Source = (Resolve-Path "$PSScriptRoot\..\..").Path,
    [ValidateSet('smoke','ssot','nav','mining','warehouse','planner')][string]$Scenario = 'smoke',
    [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 has no $IsLinux. The body runs only on pwsh 6+.
$OnLinux = $false
if ($PSVersionTable.PSVersion.Major -ge 6) { $OnLinux = $IsLinux -eq $true }
if ($Scenario -in @('nav','mining','warehouse') -and -not $OnLinux) { [Diagnostics.Process]::GetCurrentProcess().PriorityClass='High' }
if ($Scenario -in @('ssot','nav','mining','warehouse') -and !$PSBoundParameters.ContainsKey('Seconds')) { $Seconds = 900 }
if ($Scenario -eq 'planner' -and !$PSBoundParameters.ContainsKey('Seconds')) { $Seconds = 60 }

# PowerShell cmdlets accept '\' on Linux. System.IO does not.
function ConvertTo-SandboxPath([string]$Path) {
    if ($script:OnLinux) { return $Path.Replace('\', '/') }
    return $Path
}
function Write-SandboxText([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
    [IO.File]::WriteAllText((ConvertTo-SandboxPath $Path), $Text, $Encoding)
}
function Start-SandboxProcess([string]$Stdout, [string]$Stderr) {
    $arguments = '--headless --directory "{0}" --rom "{1}" --id 0' -f $run, (Join-Path $run 'rom')
    if ($script:OnLinux) {
        $proc = Start-Process -FilePath $CraftOS -ArgumentList $arguments -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    } else {
        $proc = Start-Process -FilePath $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
        $proc.PriorityClass = if ($Scenario -in @('nav','mining','warehouse')) { 'High' } else { 'AboveNormal' }
        if ($Scenario -notin @('nav','mining','warehouse')) { $proc.ProcessorAffinity = [IntPtr]1 }
    }
    return $proc
}

try {
    if ($env:LOCALAPPDATA) {
        $cache = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox'
    } else {
        $cacheRoot = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
        $cache = Join-Path $cacheRoot 'computercraft-sandbox'
    }
    $romSource = $null
    if (!$CraftOS) {
        if ($OnLinux) {
            $linuxApp = Join-Path $cache 'craftos-2.8.3-linux'
            $root = Join-Path $linuxApp 'squashfs-root'
            $CraftOS = Join-Path $root 'AppRun'
            $romSource = Join-Path $root 'usr/share/craftos'
            if (!(Test-Path -LiteralPath $CraftOS)) {
                New-Item -ItemType Directory -Force -Path $linuxApp | Out-Null
                $image = Join-Path $linuxApp 'CraftOS-PC.x86_64.AppImage'
                $url = 'https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC.x86_64.AppImage'
                if (!(Test-Path -LiteralPath $image)) {
                    Write-Output 'Downloading CraftOS-PC v2.8.3 AppImage...'
                    Invoke-WebRequest -UseBasicParsing $url -OutFile $image
                }
                if ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -ne 'f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c') {
                    Remove-Item -LiteralPath $image -Force
                    throw 'CraftOS-PC archive checksum mismatch.'
                }
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
                & /bin/chmod +x $image
                $extractLog = Join-Path $linuxApp 'extract.log'
                Push-Location $linuxApp
                try {
                    & $image --appimage-extract > $extractLog 2>&1
                    if ($LASTEXITCODE -ne 0) { throw 'CraftOS-PC AppImage extract failed.' }
                } finally {
                    Pop-Location
                }
            }
            & /bin/chmod +x $CraftOS
        } else {
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
    }
    $CraftOS = (Resolve-Path -LiteralPath $CraftOS).Path
    if (-not $romSource) {
        $romSource = Split-Path $CraftOS
        if ($OnLinux) {
            $share = Join-Path $romSource 'usr/share/craftos'
            if (Test-Path -LiteralPath (Join-Path $share 'bios.lua')) { $romSource = $share }
        }
    }
    # SDL writes ALSA and X11 errors when the host has no sound card or display. Any stderr fails the run.
    if ($OnLinux) {
        $env:SDL_AUDIODRIVER = 'dummy'
        $env:SDL_VIDEODRIVER = 'dummy'
    }
    if ((& $CraftOS --version | Select-Object -First 1) -ne 'CraftOS-PC v2.8.3') {
        if ($OnLinux) { throw 'Use CraftOS-PC v2.8.3 AppImage (squashfs-root/AppRun).' }
        throw 'Use CraftOS-PC v2.8.3 portable (CraftOS-PC_console.exe).'
    }
    $Source = (Resolve-Path -LiteralPath $Source).Path
    $run = Join-Path $cache ('runs\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path "$run\config" | Out-Null
    New-Item -ItemType Directory -Force -Path "$run\rom" | Out-Null
    Copy-Item -LiteralPath (Join-Path $romSource 'bios.lua'), (Join-Path $romSource 'rom') -Destination "$run\rom" -Recurse
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $config = @{
        standardsMode = $true; computerSpaceLimit = 4000000
        checkUpdates = $false; http_enable = $true; http_whitelist = @('*')
        keepOpenOnShutdown = $false; logErrors = $true
    } | ConvertTo-Json
    Write-SandboxText "$run\config\global.json" $config $utf8
    $roles = if ($Scenario -eq 'planner') { @('server','turtle1','turtle2') }
        elseif ($Scenario -in @('ssot','nav','mining','warehouse')) { @('server','turtle1','turtle2','turtle3','controller','world') }
        else { @('server', 'hub', 'miner') }
    if ($Scenario -eq 'mining') { $roles += 'hub' }
    for ($id = 0; $id -lt $roles.Count; $id++) {
        $disk = Join-Path (Join-Path $run 'computer') "$id"
        New-Item -ItemType Directory -Force -Path $disk | Out-Null
        # Copies, not mounts: repo scripts count towards each computer's disk limit.
        $files = if ($id -eq 0 -or $Scenario -in @('ssot','nav','mining','warehouse','planner')) { Get-ChildItem -LiteralPath $Source -Filter '*.lua' } else {
            Get-Item -LiteralPath "$Source\$($roles[$id]).lua", "$Source\miner.lua", "$Source\update.lua" | Sort-Object FullName -Unique
        }
        foreach ($file in $files) {
            # Match wget's LF text so a Windows checkout does not duplicate the HTTP cache.
            $code = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
            Write-SandboxText (Join-Path $disk $file.Name) $code $utf8
        }
        Copy-Item -LiteralPath "$PSScriptRoot\driver.lua", "$PSScriptRoot\turtle.lua" -Destination $disk
        if ($Scenario -eq 'planner') {
            Copy-Item -LiteralPath "$PSScriptRoot\planner-driver.lua" -Destination $disk
        }
        if ($Scenario -in @('ssot','nav','mining','warehouse')) {
            foreach ($testFile in @('ssot-runtime.lua','ssot-checks.lua','ssot-client-checks.lua','ssot-storage.lua','miner-ssot-checks.lua','mocks.lua','nav-checks.lua','nav-fixture.lua','miner-nav-checks.lua','mining-runtime.lua','mining-checks.lua','mining-fixture.lua','mining-unit.lua','warehouse-unit.lua','warehouse-checks.lua','warehouse-fixture.lua','warehouse-runtime.lua')) {
                $from = Join-Path (Join-Path $Source 'tests') $testFile
                if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $disk }
            }
            New-Item -ItemType Directory -Force -Path "$disk\tests" | Out-Null
            $bundle = @('mocks.lua','mining-checks.lua','warehouse-checks.lua') | ForEach-Object {
                $from = Join-Path (Join-Path $Source 'tests') $_
                if (Test-Path -LiteralPath $from) { $from }
            }
            if ($bundle) { Copy-Item -LiteralPath $bundle -Destination "$disk\tests" }
            Copy-Item -LiteralPath "$PSScriptRoot\ssot-driver.lua" -Destination $disk
            Copy-Item -LiteralPath "$Source\tests\ingame\server.lua" -Destination "$disk\test-server.lua"
            Write-SandboxText "$disk\ssot.cfg" '{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456",["3"]="test-secret-123456",["4"]="test-secret-123456"},leaseMs=30000,maxChunks=8}' $utf8
        }
        Write-SandboxText "$disk\startup.lua" "while fs.exists('boot-hold') do sleep(0.1) end; shell.run('driver.lua', '$Seconds', '$Scenario')" $utf8
    }
    Write-Output "Sandbox: local source=$Source seconds=$Seconds scenario=$Scenario standardsMode=true disk=4000000"
    Write-Output "Artifacts: $run"
    $process = Start-SandboxProcess (ConvertTo-SandboxPath "$run\stdout.log") (ConvertTo-SandboxPath "$run\stderr.log")
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds + 35)
    $restarted = $false
    do {
        if ($Scenario -in @('ssot','nav','mining','warehouse') -and !$restarted -and (Test-Path "$run\computer\4\restart-ready.json")) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
            foreach ($id in 1..4) { Write-SandboxText "$run\computer\$id\boot-hold" 'restart barrier' $utf8 }
            $process = Start-SandboxProcess (ConvertTo-SandboxPath "$run\stdout-restart.log") (ConvertTo-SandboxPath "$run\stderr-restart.log")
            Start-Sleep -Seconds 2
            foreach ($id in 1..4) { Remove-Item -LiteralPath "$run\computer\$id\boot-hold" }
            $restarted = $true
            Write-Output 'Restarted the complete CraftOS process at the durable checkpoint.'
        }
        $complete = @(0..($roles.Count - 1) | Where-Object { Test-Path -LiteralPath "$run\computer\$_\sandbox-result.json" }).Count -eq $roles.Count
        $reports = @(Get-ChildItem "$run\computer" -Recurse -Filter sandbox-result.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
        if ($complete -or $process.HasExited -or @($reports | Where-Object { !$_.ok }).Count -gt 0) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $timedOut = !$complete -and !$process.HasExited -and [DateTime]::UtcNow -ge $deadline
    $crashed = $process.HasExited
    # Keep computers alive until all reports exist: shutdown can strand sibling timers.
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
    $failed = $timedOut -or $crashed
    foreach ($id in 0..($roles.Count - 1)) {
        $path = "$run\computer\$id\sandbox-result.json"
        if (!(Test-Path -LiteralPath $path)) {
            Write-Output "$($roles[$id]): FAIL booted=unknown errors=missing result (crash or timeout)"
            $failed = $true
            continue
        }
        $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $errors = @($result.errors | Where-Object { $_ -is [string] -and $_ })
        $status = if ($result.ok) { 'PASS' } else { 'FAIL' }
        Write-Output "$($roles[$id]): $status booted=$($result.booted) errors=$($errors.Count) disk_free=$($result.free) rx=$($result.rx) http_ok=$($result.httpOK)/$($result.httpAttempts)"
        foreach ($line in $result.lines) { Write-Output "  last: $line" }
        foreach ($errorText in $errors) { Write-Output "  error: $errorText" }
        if (!$result.ok) { $failed = $true }
    }
    $stderr = Get-Content -LiteralPath "$run\stderr.log" -Raw
    if ($stderr) { Write-Output "Emulator stderr: $stderr"; $failed = $true }
    if ($timedOut) { Write-Output 'Emulator timed out.' }
    if ($crashed) { Write-Output "Emulator exited early: $($process.ExitCode)" }
    if ($Output) {
        New-Item -ItemType Directory -Force -Path $Output | Out-Null
        Copy-Item -LiteralPath "$run\computer", "$run\stdout.log", "$run\stderr.log", "$run\config" -Destination $Output -Recurse -Force
        Get-ChildItem -LiteralPath $run -Filter '*.log' | Copy-Item -Destination $Output -Force
    }
    if ($failed) { Write-Output 'Sandbox FAIL'; exit 1 }
    if ($Scenario -eq 'nav') {
        & "$Source\tests\ingame\verify-results.ps1" -Computers "$run\computer" -Output $Output -Title 'Navigation PR 2'
    }
    if ($Scenario -eq 'mining') {
        & "$Source\tests\ingame\verify-mining.ps1" -Computers "$run\computer" -Output $Output
    }
    if ($Scenario -eq 'warehouse') {
        & "$Source\tests\ingame\verify-warehouse.ps1" -Computers "$run\computer" -Output $Output
    }
    Write-Output 'Sandbox PASS'
    exit 0
} catch {
    Write-Output "Sandbox FAIL: $($_.Exception.Message)"
    exit 1
}
