param(
    [string]$Output,
    [string]$CraftOS = '',
    [int]$Seconds = 900,
    [int]$Disk = 1000000
)
$ErrorActionPreference = 'Stop'
if (!$Output) { throw 'The P0 probe requires an evidence output directory.' }
$OnLinux = $false
if ($PSVersionTable.PSVersion.Major -ge 6) { $OnLinux = $IsLinux -eq $true }

function ConvertTo-ProbePath([string]$Path) {
    if ($script:OnLinux) { return $Path.Replace('\', '/') }
    return $Path
}

$romSource = $null
if (!$CraftOS) {
    if ($OnLinux) {
        $cacheRoot = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
        $linuxApp = Join-Path (Join-Path $cacheRoot 'computercraft-sandbox') 'craftos-2.8.3-linux'
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
            $hash = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
            if ($hash -ne 'f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c') {
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
        $CraftOS = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox\craftos-2.8.3\CraftOS-PC_console.exe'
    }
}
if (!(Test-Path -LiteralPath $CraftOS)) { throw "CraftOS-PC was not found at $CraftOS" }
$CraftOS = (Resolve-Path -LiteralPath $CraftOS).Path
if (-not $romSource) {
    $romSource = Split-Path $CraftOS
    if ($OnLinux) {
        $share = Join-Path $romSource 'usr/share/craftos'
        if (Test-Path -LiteralPath (Join-Path $share 'bios.lua')) { $romSource = $share }
    }
}
$version = & $CraftOS --version | Select-Object -First 1
if ($version -ne 'CraftOS-PC v2.8.3') { throw "Use CraftOS-PC v2.8.3. Got: $version" }

$run = Join-Path $Output ('sandbox-' + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $run 'config'
$computerRoot = Join-Path $run 'computer'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
& "$PSScriptRoot\prepare.ps1" -Computers $computerRoot
$settings = @{
    standardsMode = $true
    computerSpaceLimit = $Disk
    checkUpdates = $false
    keepOpenOnShutdown = $false
    useHardwareRenderer = $false
    useWebP = $false
    http_enable = $true
    http_whitelist = @('*')
} | ConvertTo-Json
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((ConvertTo-ProbePath (Join-Path $configDir 'global.json')), $settings, $utf8)
$oldVideo, $oldAudio = $env:SDL_VIDEODRIVER, $env:SDL_AUDIODRIVER
$processes = @()
try {
    $env:SDL_VIDEODRIVER = 'dummy'
    $env:SDL_AUDIODRIVER = 'dummy'
    foreach ($id in 0..2) {
        $stdout = ConvertTo-ProbePath (Join-Path $run "stdout-$id.log")
        $stderr = ConvertTo-ProbePath (Join-Path $run "stderr-$id.log")
        if ($OnLinux) {
            $arguments = @('--gui', '--directory', $run, '--rom', $romSource, '--id', "$id")
            $process = Start-Process -FilePath $CraftOS -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        } else {
            $arguments = '--gui --directory "{0}" --rom "{1}" --id {2}' -f $run, $romSource, $id
            $process = Start-Process -FilePath $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $process.PriorityClass = 'High'
        }
        $processes += $process
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $finished = @(0..2 | Where-Object { Test-Path (Join-Path (Join-Path $computerRoot "$_") 'initial-complete') }).Count -eq 3
        if ($finished -or @($processes | Where-Object HasExited).Count) { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    $summary = @{runtime='CraftOS-PC'; run=$run; complete=$finished; computers=3; mockTurtles=2; disk=$Disk; gpsHosts=0}
    $summary | ConvertTo-Json | Set-Content (Join-Path $Output 'gateA-run.json')
    if (!$finished) { throw "P0 sandbox did not finish. Evidence remains at $run" }
    foreach ($id in 0..2) {
        $initialPath = Join-Path (Join-Path (Join-Path $computerRoot "$id") 'results') 'initial.json'
        $initial = Get-Content $initialPath -Raw | ConvertFrom-Json
        if (!$initial.ok) { throw "Computer $id has a failed probe. Evidence remains at $run" }
    }
    Write-Output "P0 sandbox probes finished. Evidence at $run"
} finally {
    foreach ($process in $processes) {
        if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
    $env:SDL_VIDEODRIVER = $oldVideo
    $env:SDL_AUDIODRIVER = $oldAudio
}
