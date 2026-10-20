param(
    [ValidateRange(15, 3600)][int]$Seconds = 30,
    [string]$CraftOS = $env:CRAFTOS_PC,
    [string]$Source = (Resolve-Path "$PSScriptRoot\..\..").Path,
    [ValidateSet('smoke','ssot','nav','mining','warehouse','wh2-wizard')][string]$Scenario = 'smoke',
    [string]$Output = '',
    [ValidateRange(1000000, 16000000)][int]$DiskLimit = 4000000,
    [string]$DataRoot = ''
)
$ErrorActionPreference = 'Stop'
$wizard = $Scenario -eq 'wh2-wizard'
if ($wizard) { $previousVideo = $env:SDL_VIDEODRIVER; $previousAudio = $env:SDL_AUDIODRIVER }
if ($wizard -and !$PSBoundParameters.ContainsKey('DiskLimit')) { $DiskLimit = 1000000 }
if ($wizard -and $DiskLimit -ne 1000000) { throw 'The wizard scenario requires a 1000000-byte disk on every computer.' }
if ($Scenario -in @('nav','mining','warehouse')) { [Diagnostics.Process]::GetCurrentProcess().PriorityClass='High' }
if ($Scenario -in @('ssot','nav','mining','warehouse','wh2-wizard') -and !$PSBoundParameters.ContainsKey('Seconds')) { $Seconds = 900 }

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
    if ($wizard) {
        . "$Source\tests\wh2-wizard-gate-host.ps1"
        $plan = Get-Content -LiteralPath "$Source\tests\wh2-wizard-gate-plan.json" -Raw | ConvertFrom-Json
        $bindings = if ($env:WH2_WIZARD_GATE_BINDINGS) { $env:WH2_WIZARD_GATE_BINDINGS } else { "$Source\tests\wh2-wizard-gate-bindings.lua" }
    }
    $runBase = if ($DataRoot) { $DataRoot } else { Join-Path $cache 'runs' }
    $run = Join-Path $runBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path "$run\config" | Out-Null
    New-Item -ItemType Directory -Force -Path "$run\rom" | Out-Null
    Copy-Item -LiteralPath "$app\bios.lua", "$app\rom" -Destination "$run\rom" -Recurse
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $sourceBytes = @{}
    function Copy-SandboxFile([string]$Path, [string]$Destination) {
        if (!$sourceBytes.ContainsKey($Path)) {
            $sourceBytes[$Path] = if ([IO.Path]::GetExtension($Path) -eq '.lua') { $utf8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n", "`n")) } else { [IO.File]::ReadAllBytes($Path) }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
        [IO.File]::WriteAllBytes($Destination, $sourceBytes[$Path])
    }
    $config = @{
        standardsMode = $true; computerSpaceLimit = $DiskLimit
        checkUpdates = $false; http_enable = $true; http_whitelist = @('*')
        keepOpenOnShutdown = $false; logErrors = $true
        useHardwareRenderer = $false; useWebP = $false
    } | ConvertTo-Json
    [IO.File]::WriteAllText("$run\config\global.json", $config, $utf8)
    $roles = if ($wizard) { @('server','turtle1','turtle2','turtle3','turtle4','board1','board2') } elseif ($Scenario -in @('ssot','nav','mining','warehouse')) { @('server','turtle1','turtle2','turtle3','controller','world') } else { @('server', 'hub', 'miner') }
    if ($Scenario -eq 'mining') { $roles += 'hub' }
    $diskInventory = @()
    for ($id = 0; $id -lt $roles.Count; $id++) {
        $disk = "$run\computer\$id"
        $role = $roles[$id]
        $missing = @()
        New-Item -ItemType Directory -Force -Path $disk | Out-Null
        # Copies, not mounts: repo scripts count towards each computer's disk limit.
        $files = if ($wizard) {
            $gateRole = if ($id -eq 0) { 'server' } else { 'client' }
            foreach ($name in @(Get-WizardGateFiles -Source $Source -Role $gateRole)) {
                $path = Join-Path $Source $name
                if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Item -LiteralPath $path }
            }
        } elseif ($Scenario -eq 'smoke') {
            $names = switch ($role) {
                'server' { @('server.lua','fleetview.lua','update.lua','atomic.lua','ssot.lua','mine-tasks.lua','warehouse-tasks.lua') }
                'hub' { @('hub.lua','miner.lua','fleetview.lua','update.lua') }
                'miner' { @('miner.lua','update.lua','atomic.lua','ssot.lua','ssot-client.lua','nav.lua','mine-tasks.lua','mining.lua','warehouse-tasks.lua','warehouse.lua','store.lua') }
            }
            foreach ($name in $names) { Get-Item -LiteralPath (Join-Path $Source $name) }
        } elseif ($id -eq 0 -or $Scenario -in @('ssot','nav','mining','warehouse')) { Get-ChildItem -LiteralPath $Source -Filter '*.lua' } else {
            Get-Item -LiteralPath "$Source\$($roles[$id]).lua", "$Source\miner.lua", "$Source\update.lua" | Sort-Object FullName -Unique
        }
        foreach ($file in $files) {
            $relative = if ($wizard) { $file.FullName.Substring($Source.TrimEnd('\','/').Length + 1) } else { $file.Name }
            $target = Join-Path $disk $relative
            Copy-SandboxFile $file.FullName $target
        }
        if (!$wizard) { Copy-Item -LiteralPath "$PSScriptRoot\driver.lua", "$PSScriptRoot\turtle.lua" -Destination $disk }
        if ($wizard) {
            foreach ($name in @('wh2-wizard-gate-runtime.lua','wh2-wizard-gate-checks.lua','wh2-wizard-gate-inventory.lua')) {
                if (Test-Path -LiteralPath "$Source\tests\$name") { Copy-SandboxFile "$Source\tests\$name" "$disk\$name" }
            }
            Copy-SandboxFile "$PSScriptRoot\wh2-wizard-driver.lua" "$disk\wh2-wizard-driver.lua"
            Copy-SandboxFile "$Source\tests\wh2-wizard-gate-plan.json" "$disk\wizard-plan.json"
            Copy-SandboxFile "$Source\tests\wh2-wizard-gate-prerequisites.json" "$disk\wh2-wizard-gate-prerequisites.json"
            if (Test-Path -LiteralPath $bindings -PathType Leaf) { Copy-SandboxFile $bindings "$disk\wh2-wizard-gate-bindings.lua" }
            $role = if ($id -eq 0) { 'server' } elseif ($id -le 4) { 'turtle' } else { 'board' }
            $wizardConfig = @{schema=1;enabled=$true;role=$role;computerId=$id;serverId=0;operators=@{'5'=$true;'6'=$true};diskLimit=$DiskLimit;unknowns=$plan.unknowns;sampleSeconds=$plan.sampleSeconds;runtime='sandbox';runId=(Split-Path $run -Leaf);outputLimitBytes=393216}
            [IO.File]::WriteAllText("$disk\wizard-config.json", ($wizardConfig | ConvertTo-Json -Depth 8), $utf8)
            $missing = @(Get-WizardGateMissing -Source $Source -Role $gateRole -Bindings $bindings)
        }
        if ($Scenario -in @('ssot','nav','mining','warehouse')) {
            foreach ($testFile in @('ssot-runtime.lua','ssot-checks.lua','ssot-client-checks.lua','ssot-storage.lua','miner-ssot-checks.lua','mocks.lua','nav-checks.lua','nav-fixture.lua','miner-nav-checks.lua','mining-runtime.lua','mining-checks.lua','mining-fixture.lua','mining-unit.lua','warehouse-unit.lua','warehouse-checks.lua','warehouse-fixture.lua','warehouse-runtime.lua')) {
                Copy-Item -LiteralPath "$Source\tests\$testFile" -Destination $disk
            }
            New-Item -ItemType Directory -Force -Path "$disk\tests" | Out-Null
            Copy-Item "$Source\tests\mocks.lua", "$Source\tests\mining-checks.lua", "$Source\tests\warehouse-checks.lua" "$disk\tests"
            Copy-Item -LiteralPath "$PSScriptRoot\ssot-driver.lua" -Destination $disk
            Copy-Item -LiteralPath "$Source\tests\ingame\server.lua" -Destination "$disk\test-server.lua"
            [IO.File]::WriteAllText("$disk\ssot.cfg", '{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456",["3"]="test-secret-123456",["4"]="test-secret-123456"},leaseMs=30000,maxChunks=8}', $utf8)
        }
        $entrypoint = if ($wizard) { 'wh2-wizard-driver.lua' } else { 'driver.lua' }
        [IO.File]::WriteAllText("$disk\startup.lua", "while fs.exists('boot-hold') do sleep(0.1) end; shell.run('$entrypoint', '$Seconds', '$Scenario', '$DiskLimit')", $utf8)
        $staged = @(Get-ChildItem -LiteralPath $disk -File -Recurse)
        $bytes = ($staged | Measure-Object -Property Length -Sum).Sum
        $diskInventory += @{computerId=$id;role=$role;capacity=$DiskLimit;stagedBytes=$bytes;headroom=$DiskLimit-$bytes;missing=$missing;files=@($staged | ForEach-Object { @{path=$_.FullName.Substring($disk.Length+1);bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash} })}
        if ($bytes -ge $DiskLimit) { throw "Computer $id staged $bytes bytes, which exceeds its $DiskLimit-byte capacity." }
    }
    [IO.File]::WriteAllText("$run\staged-disk-sizes.json", ($diskInventory | ConvertTo-Json -Depth 12), $utf8)
    [IO.File]::WriteAllText("$run\source.json", (@{commit=(& git -C $Source rev-parse HEAD);scenario=$Scenario;source=$Source;capacity=$DiskLimit;roles=$roles;hostScriptSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash} | ConvertTo-Json), $utf8)
    Write-Output "Sandbox: local source=$Source seconds=$Seconds scenario=$Scenario standardsMode=true disk=$DiskLimit"
    Write-Output "Artifacts: $run"
    $display = if ($wizard) { '--gui' } else { '--headless' }
    if ($wizard) { $env:SDL_VIDEODRIVER = 'dummy'; $env:SDL_AUDIODRIVER = 'dummy' }
    $arguments = '{0} --directory "{1}" --rom "{2}" --id 0' -f $display, $run, "$run\rom"
    $process = Start-Process -FilePath $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run\stdout.log" -RedirectStandardError "$run\stderr.log"
    [IO.File]::WriteAllText("$run\emulator.json", (@{path=$CraftOS;version='2.8.3';sha256=(Get-FileHash -LiteralPath $CraftOS -Algorithm SHA256).Hash;arguments=$arguments;pid=$process.Id} | ConvertTo-Json), $utf8)
    $process.PriorityClass = if ($Scenario -in @('nav','mining','warehouse')) { 'High' } else { 'AboveNormal' }
    if ($Scenario -notin @('nav','mining','warehouse')) { $process.ProcessorAffinity = [IntPtr]1 }
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds + 35)
    $restarted = $false
    do {
        if ($Scenario -in @('ssot','nav','mining','warehouse') -and !$restarted -and (Test-Path "$run\computer\4\restart-ready.json")) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
            foreach ($id in 1..4) { [IO.File]::WriteAllText("$run\computer\$id\boot-hold", 'restart barrier', $utf8) }
            $process = Start-Process -FilePath $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$run\stdout-restart.log" -RedirectStandardError "$run\stderr-restart.log"
            $process.PriorityClass = if ($Scenario -in @('nav','mining','warehouse')) { 'High' } else { 'AboveNormal' }
            if ($Scenario -notin @('nav','mining','warehouse')) { $process.ProcessorAffinity = [IntPtr]1 }
            Start-Sleep -Seconds 2
            foreach ($id in 1..4) { Remove-Item -LiteralPath "$run\computer\$id\boot-hold" }
            $restarted = $true
            Write-Output 'Restarted the complete CraftOS process at the durable checkpoint.'
        }
        $complete = @(0..($roles.Count - 1) | Where-Object { Test-Path -LiteralPath "$run\computer\$_\sandbox-result.json" }).Count -eq $roles.Count
        $reports = @(Get-ChildItem "$run\computer" -Recurse -Filter sandbox-result.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
        if ($complete -or $process.HasExited -or (!$wizard -and @($reports | Where-Object { !$_.ok }).Count -gt 0)) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    $timedOut = !$complete -and !$process.HasExited -and [DateTime]::UtcNow -ge $deadline
    $crashed = $process.HasExited
    # Keep computers alive until all reports exist: shutdown can strand sibling timers.
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
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
        if ($wizard) { Write-Output "$($roles[$id]): $status booted=$($result.booted) capacity=$($result.capacity) disk_free=$($result.free) errors=$($errors.Count)" }
        else { Write-Output "$($roles[$id]): $status booted=$($result.booted) errors=$($errors.Count) disk_free=$($result.free) rx=$($result.rx) http_ok=$($result.httpOK)/$($result.httpAttempts)" }
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
        Get-ChildItem -LiteralPath $run -Filter '*.json' | Copy-Item -Destination $Output -Force
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
} finally {
    if ($wizard) { $env:SDL_VIDEODRIVER = $previousVideo; $env:SDL_AUDIODRIVER = $previousAudio }
}
