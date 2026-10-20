param(
    [ValidateRange(15, 86400)][int]$Seconds = 30,
    [string]$CraftOS = $env:CRAFTOS_PC,
    [string]$Source = (Resolve-Path "$PSScriptRoot\..\..").Path,
    [ValidateSet('smoke','ssot','nav','mining','warehouse','ar','views','install','bench','planner','fleet')][string]$Scenario = 'smoke',
    [string]$Output = '',
    [string]$DataRoot = '',
    [ValidateRange(100000, 64000000)][int]$Disk = 4000000
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 has no $IsLinux. The body runs only on pwsh 6+.
$OnLinux = $false
if ($PSVersionTable.PSVersion.Major -ge 6) { $OnLinux = $IsLinux -eq $true }
$previousVideo=$env:SDL_VIDEODRIVER
$previousAudio=$env:SDL_AUDIODRIVER
if ($OnLinux -or $Scenario -eq 'views') { $env:SDL_VIDEODRIVER='dummy'; $env:SDL_AUDIODRIVER='dummy' }
if ($Scenario -in @('nav','mining','warehouse') -and -not $OnLinux) { [Diagnostics.Process]::GetCurrentProcess().PriorityClass='High' }
if ($Scenario -in @('ssot','nav','mining','warehouse','ar','views','fleet') -and !$PSBoundParameters.ContainsKey('Seconds')) { $Seconds = 900 }
if ($Scenario -eq 'install' -and !$PSBoundParameters.ContainsKey('Seconds')) { $Seconds = 120 }
$process = $null

# PowerShell cmdlets accept '\' on Linux. System.IO and CraftOS do not.
if ($Scenario -eq 'planner' -and !$PSBoundParameters.ContainsKey('Seconds')) { $Seconds = 60 }
function ConvertTo-SandboxPath([string]$Path) {
    if ($script:OnLinux) { return $Path.Replace('\', '/') }
    return $Path
}
function Write-SandboxText([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
    [IO.File]::WriteAllText((ConvertTo-SandboxPath $Path), $Text, $Encoding)
}
function Start-SandboxProcess([string]$Stdout, [string]$Stderr) {
    $mode = if ($Scenario -eq 'views') { '--gui' } else { '--headless' }
    $directory = ConvertTo-SandboxPath $run
    $rom = ConvertTo-SandboxPath (Join-Path $run 'rom')
    $arguments = "$mode --directory `"$directory`" --rom `"$rom`" --id 0"
    if ($script:OnLinux) {
        return Start-Process -FilePath $CraftOS -ArgumentList $arguments -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    }
    $proc = Start-Process -FilePath $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    $proc.PriorityClass = if ($Scenario -in @('nav','mining','warehouse')) { 'High' } else { 'AboveNormal' }
    if ($Scenario -notin @('nav','mining','warehouse','ar','views')) { $proc.ProcessorAffinity = [IntPtr]1 }
    return $proc
}
if ($Scenario -eq 'bench') {
    if (!$PSBoundParameters.ContainsKey('Disk')) { $Disk = 1000000 }
    if (!$PSBoundParameters.ContainsKey('Seconds')) { $Seconds = 900 }
    & "$PSScriptRoot\..\bench\gateA.ps1" -Output $Output -CraftOS $CraftOS -Seconds $Seconds -Disk $Disk
    exit $LASTEXITCODE
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
    if (!$DataRoot) { $DataRoot = Join-Path $cache 'runs' }
    if ($Scenario -eq 'views' -and -not $OnLinux) {
        $run = Join-Path 'C:\Work\gemini-input\p2\evidence\pr5\gateA\runs' ([guid]::NewGuid().ToString('N'))
    } else {
        $run = Join-Path $DataRoot ([guid]::NewGuid().ToString('N'))
    }
    New-Item -ItemType Directory -Force -Path "$run\config" | Out-Null
    New-Item -ItemType Directory -Force -Path "$run\rom" | Out-Null
    Copy-Item -LiteralPath (Join-Path $romSource 'bios.lua'), (Join-Path $romSource 'rom') -Destination "$run\rom" -Recurse
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $diskLimit = if ($Scenario -eq 'install') { 1000000 } else { 4000000 }
    $config = @{
        standardsMode = $true; computerSpaceLimit = $diskLimit
        checkUpdates = $false; http_enable = $true; http_whitelist = @('*')
        keepOpenOnShutdown = $false; logErrors = $true
        useHardwareRenderer = $false; useWebP = $false
    } | ConvertTo-Json
    Write-SandboxText "$run\config\global.json" $config $utf8
    if ($Scenario -eq 'planner') {
        $roles = @('server','turtle1','turtle2')
    } elseif ($Scenario -eq 'fleet') {
        $roles = @('server','turtle1','turtle2','turtle3','operator')
    } elseif ($Scenario -eq 'install') {
        # Payloads live in the ROM so they do not count against the 1000000 byte disk.
        $payload = Join-Path (Join-Path (Join-Path $run 'rom') 'rom') 'bundle'
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        foreach ($file in (Get-ChildItem -LiteralPath $Source -Filter '*.lua' -File)) {
            $code = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
            Write-SandboxText (Join-Path $payload $file.Name) $code $utf8
        }
        $roles = @('installer')
    } elseif ($Scenario -in @('ssot','nav','mining','warehouse','views')) {
        $roles = @('server','turtle1','turtle2','turtle3','controller','world')
    } else {
        $roles = @('server', 'hub', 'miner')
    }
    if ($Scenario -in @('mining','views')) { $roles += 'hub' }
    if ($Scenario -eq 'ar') { $roles = @('server','turtle1','turtle2','turtle3','controller','hub') }
    $sourceProof=@()
    $viewsNetwork=Get-Random -Minimum 100000 -Maximum 2000000000
    $bundleNames=@('ssot-runtime.lua','ssot-checks.lua','ssot-client-checks.lua','ssot-storage.lua','miner-ssot-checks.lua','mocks.lua','nav-checks.lua','nav-fixture.lua','miner-nav-checks.lua','mining-runtime.lua','mining-checks.lua','mining-fixture.lua','mining-unit.lua','warehouse-unit.lua','warehouse-checks.lua','warehouse-fixture.lua','warehouse-runtime.lua')
    for ($id = 0; $id -lt $roles.Count; $id++) {
        $disk = Join-Path (Join-Path $run 'computer') "$id"
        New-Item -ItemType Directory -Force -Path $disk | Out-Null
        if ($Scenario -eq 'install') {
            foreach ($name in @('install.lua','update.lua','install-roles.lua','install-core.lua','install-keys.lua','install-shell.lua','install-touch.lua','enrol.lua')) {
                $code = [IO.File]::ReadAllText((Join-Path $Source $name)).Replace("`r`n", "`n")
                Write-SandboxText (Join-Path $disk $name) $code $utf8
            }
            foreach ($pair in @(
                @{ From = (Join-Path $Source 'tests\install-unit.lua'); Name = 'install-unit.lua' },
                @{ From = (Join-Path $Source 'tests\i2-touch.lua'); Name = 'i2-touch.lua' },
                @{ From = (Join-Path $PSScriptRoot 'install-driver.lua'); Name = 'install-driver.lua' }
            )) {
                $code = [IO.File]::ReadAllText($pair.From).Replace("`r`n", "`n")
                Write-SandboxText (Join-Path $disk $pair.Name) $code $utf8
            }
            $eventSrc = Join-Path $Source 'tests\i2-events'
            $eventDst = Join-Path $disk 'i2-events'
            New-Item -ItemType Directory -Force -Path $eventDst | Out-Null
            Get-ChildItem -LiteralPath $eventSrc -Filter '*.lua' | ForEach-Object {
                $code = [IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n")
                Write-SandboxText (Join-Path $eventDst $_.Name) $code $utf8
            }
            Write-SandboxText (Join-Path $disk 'startup.lua') "shell.run('install-driver.lua')" $utf8
            continue
        }
        # Copies, not mounts: repo scripts count towards each computer's disk limit.
        $files = if ($id -eq 0 -or $Scenario -in @('ssot','nav','mining','warehouse','ar','views','planner','fleet')) { Get-ChildItem -LiteralPath $Source -Filter '*.lua' } else {
            Get-Item -LiteralPath "$Source\$($roles[$id]).lua", "$Source\miner.lua", "$Source\update.lua" | Sort-Object FullName -Unique
        }
        foreach ($file in $files) {
            # Match wget's LF text so a Windows checkout does not duplicate the HTTP cache.
            $code = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
            $dest = Join-Path $disk $file.Name
            Write-SandboxText $dest $code $utf8
            if ($Scenario -eq 'views') {
                $sha=[Security.Cryptography.SHA256]::Create()
                try { $expected=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($code))).Replace('-','') } finally { $sha.Dispose() }
                $actual=(Get-FileHash -LiteralPath (ConvertTo-SandboxPath $dest) -Algorithm SHA256).Hash
                if ($actual -ne $expected) { throw "Source copy differs for $($file.Name) on computer $id." }
                $sourceProof += [pscustomobject]@{computer=$id;file=$file.Name;sha256=$actual;normalization='LF'}
            }
        }
        Copy-Item -LiteralPath "$PSScriptRoot\driver.lua", "$PSScriptRoot\turtle.lua" -Destination $disk
        if ($Scenario -eq 'planner') {
            Copy-Item -LiteralPath "$PSScriptRoot\planner-driver.lua" -Destination $disk
        }
        if ($Scenario -eq 'fleet') {
            Copy-Item -LiteralPath "$PSScriptRoot\fleet-driver.lua" -Destination $disk
        }
        if ($Scenario -eq 'ar') {
            New-Item -ItemType Directory -Force -Path "$disk\tests" | Out-Null
            Copy-Item -LiteralPath "$PSScriptRoot\ar-driver.lua" -Destination $disk
            foreach ($testFile in @('ar-fixture.lua','ar-runtime.lua','mocks.lua','ar-hud-unit.lua','ar-snapshot-checks.lua',
                'chat-checks.lua','auth-review-checks.lua','recharge-review-checks.lua','nav-fixture.lua','install-checks.lua','install-role-checks.lua')) {
                if (Test-Path "$Source\tests\$testFile") {
                    Copy-Item -LiteralPath "$Source\tests\$testFile" -Destination "$disk\tests"
                }
            }
            New-Item -ItemType Directory -Force -Path "$disk\tests\fixtures" | Out-Null
            Copy-Item -LiteralPath "$Source\tests\fixtures\update-v1.lua" -Destination "$disk\tests\fixtures"
        }
        if ($Scenario -in @('ssot','nav','mining','warehouse','views')) {
            foreach ($testFile in $bundleNames) {
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
        if ($Scenario -eq 'views') {
            $runtime = Join-Path (Join-Path $Source 'tests') 'views-runtime.lua'
            if (!(Test-Path -LiteralPath $runtime)) { throw 'views-runtime.lua is required for the views scenario.' }
            Copy-Item -LiteralPath $runtime, "$PSScriptRoot\views-driver.lua" -Destination $disk
            Write-SandboxText "$disk\views-network" ([string]$viewsNetwork) $utf8
            Write-SandboxText "$disk\ssot.cfg" '{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456",["3"]="test-secret-123456",["4"]="test-secret-123456",["6"]="test-secret-123456"},leaseMs=30000,maxChunks=8}' $utf8
        }
        Write-SandboxText "$disk\startup.lua" "while fs.exists('boot-hold') do sleep(0.1) end; shell.run('driver.lua', '$Seconds', '$Scenario')" $utf8
    }
    Write-Output "Sandbox: local source=$Source seconds=$Seconds scenario=$Scenario standardsMode=true disk=$diskLimit"
    if ($Scenario -eq 'views') { $sourceProof | ConvertTo-Json | Set-Content "$run\source-sha256.json" }
    Write-Output "Artifacts: $run"
    $process = Start-SandboxProcess (ConvertTo-SandboxPath "$run\stdout.log") (ConvertTo-SandboxPath "$run\stderr.log")
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds + 35)
    $restarted = $false
    do {
        if ($Scenario -in @('ssot','nav','mining','warehouse','ar') -and !$restarted -and (Test-Path "$run\computer\4\restart-ready.json")) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
            foreach ($id in 1..4) { Write-SandboxText "$run\computer\$id\boot-hold" 'restart barrier' $utf8 }
            $process = Start-SandboxProcess (ConvertTo-SandboxPath "$run\stdout-restart.log") (ConvertTo-SandboxPath "$run\stderr-restart.log")
            Start-Sleep -Seconds 2
            foreach ($held in 1..4) { Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $run 'computer') "$held") 'boot-hold') }
            $restarted = $true
            Write-Output 'Restarted the complete CraftOS process at the durable checkpoint.'
        }
        $complete = @(0..($roles.Count - 1) | Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $run 'computer') "$_") 'sandbox-result.json') }).Count -eq $roles.Count
        $reports = @(Get-ChildItem (Join-Path $run 'computer') -Recurse -Filter sandbox-result.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
        if ($complete -or $process.HasExited -or (!$wizard -and @($reports | Where-Object { !$_.ok }).Count -gt 0)) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $timedOut = !$complete -and !$process.HasExited -and [DateTime]::UtcNow -ge $deadline
    $crashed = $process.HasExited
    # Keep computers alive until all reports exist: shutdown can strand sibling timers.
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
    $failed = $timedOut -or $crashed
    foreach ($id in 0..($roles.Count - 1)) {
        $path = Join-Path (Join-Path (Join-Path $run 'computer') "$id") 'sandbox-result.json'
        if (!(Test-Path -LiteralPath $path)) {
            Write-Output "$($roles[$id]): FAIL booted=unknown errors=missing result (crash or timeout)"
            $failed = $true
            continue
        }
        $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $errors = @($result.errors | Where-Object { $_ -is [string] -and $_ })
        $status = if ($result.ok) { 'PASS' } else { 'FAIL' }
        if ($wizard) { Write-Output "$($roles[$id]): $status booted=$($result.booted) capacity=$($result.capacity) disk_free=$($result.free) errors=$($errors.Count)" }
        else { Write-Output "$($roles[$id]): $status booted=$($result.booted) errors=$($errors.Count) disk_free=$($result.free) rx=$($result.rx) http_ok=$($result.httpOK)/$($result.httpAttempts)" }
        foreach ($line in $result.lines) { Write-Output "  last: $line" }
        foreach ($errorText in $errors) { Write-Output "  error: $errorText" }
        if (!$result.ok) { $failed = $true }
    }
    $stderrPath = ConvertTo-SandboxPath "$run\stderr.log"
    if (Test-Path -LiteralPath $stderrPath) {
        $stderr = Get-Content -LiteralPath $stderrPath -Raw
        if ($stderr) { Write-Output "Emulator stderr: $stderr"; $failed = $true }
    }
    if ($timedOut) { Write-Output 'Emulator timed out.' }
    if ($crashed) { Write-Output "Emulator exited early: $($process.ExitCode)" }
    if ($Output) {
        New-Item -ItemType Directory -Force -Path $Output | Out-Null
        Copy-Item -LiteralPath (Join-Path $run 'computer'), $stdout, $stderrPath, (Join-Path $run 'config') -Destination $Output -Recurse -Force
        Get-ChildItem -LiteralPath $run -Filter '*.log' | Copy-Item -Destination $Output -Force
        if ($Scenario -eq 'ar') {
            $checks = if (Test-Path "$run\computer\4\checks.json") { Get-Content "$run\computer\4\checks.json" -Raw | ConvertFrom-Json } else { @() }
            $coverage = @{
                passed = !$failed
                emulator = 'CraftOS-PC 2.8.3'
                computers = $roles
                diskCapacity = 4000000
                nativeTransport = 'CraftOS virtual modem rednet'
                checks = $checks
                limitations = @(
                    'cc_ar 0.2.1 depth-tests 3D lines and text. This sandbox does not claim through-wall outlines.'
                    'cc_ar calls use a signature-checking mock; goggles projection requires Gate B.'
                    'AP chat tuples run through production parsing; real chat_box event emission requires Gate B.'
                    'Installer rollback and disk faults use mocks inside CraftOS.'
                    'The warehouse runtime comes from main. PR 5 view roles await the corrected branch.'
                    'Owner checks sample separate controller mocks; they do not render two computers into one real goggles scene.'
                    'Controller mock elements reset on process restart; persisted external AR element cleanup is covered by module checks only.'
                )
            }
            Write-SandboxText "$Output\coverage.json" ($coverage | ConvertTo-Json -Depth 8) $utf8
        }
        if (Test-Path "$run\source-sha256.json") { Copy-Item "$run\source-sha256.json" $Output -Force }
    }
    if ($Scenario -eq 'h3') {
        Test-H3Results -Computers "$run\computer" -Output $Output -RequireFullSoak:($Seconds -ge 7200)
    }
    if ($failed) { Write-Output 'Sandbox FAIL'; exit 1 }
    if ($Scenario -eq 'nav') {
        & (Join-Path (Join-Path $Source 'tests') 'ingame/verify-results.ps1') -Computers (Join-Path $run 'computer') -Output $Output -Title 'Navigation PR 2'
    }
    if ($Scenario -eq 'mining') {
        & (Join-Path (Join-Path $Source 'tests') 'ingame/verify-mining.ps1') -Computers (Join-Path $run 'computer') -Output $Output
    }
    if ($Scenario -eq 'warehouse') {
        & (Join-Path (Join-Path $Source 'tests') 'ingame/verify-warehouse.ps1') -Computers (Join-Path $run 'computer') -Output $Output
    }
    Write-Output 'Sandbox PASS'
    exit 0
} catch {
    if ($Scenario -eq 'h3' -and $Output -and (Test-Path -LiteralPath $Output) -and !(Test-Path -LiteralPath "$Output\h3-results.json")) {
        $failure = @{ok=$false;scenario='h3';gateEligible=$false;errors=@($_.Exception.Message)} | ConvertTo-Json
        [IO.File]::WriteAllText("$Output\h3-results.json", $failure)
    }
    Write-Output "Sandbox FAIL: $($_.Exception.Message)"
    exit 1
} finally {
    $env:SDL_VIDEODRIVER=$previousVideo
    $env:SDL_AUDIODRIVER=$previousAudio
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
}
