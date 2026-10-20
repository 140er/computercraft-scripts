# Gate A for H4d. Two store peers and one computer at 1,000,000 bytes.
# Linux uses the CraftOS-PC 2.8.3 AppImage. Windows uses the portable zip.
param(
    [string]$CraftOS = $env:CRAFTOS_PC,
    [string]$Source = (Resolve-Path "$PSScriptRoot\..").Path,
    [int]$Seconds = 180
)
$ErrorActionPreference = 'Stop'
$OnLinux = $false
if ($PSVersionTable.PSVersion.Major -ge 6) { $OnLinux = $IsLinux -eq $true }

function ConvertTo-SandboxPath([string]$Path) {
    if ($script:OnLinux) { return $Path.Replace('\', '/') }
    return $Path
}
function Write-SandboxText([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
    [IO.File]::WriteAllText((ConvertTo-SandboxPath $Path), $Text, $Encoding)
}

if ($env:LOCALAPPDATA) {
    $cache = Join-Path $env:LOCALAPPDATA 'computercraft-sandbox'
} else {
    $cacheRoot = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
    $cache = Join-Path $cacheRoot 'computercraft-sandbox'
}
$romSource = $null
if (-not $CraftOS) {
    if ($OnLinux) {
        $linuxApp = Join-Path $cache 'craftos-2.8.3-linux'
        $root = Join-Path $linuxApp 'squashfs-root'
        $CraftOS = Join-Path $root 'AppRun'
        $romSource = Join-Path $root 'usr/share/craftos'
        if (-not (Test-Path -LiteralPath $CraftOS)) {
            New-Item -ItemType Directory -Force -Path $linuxApp | Out-Null
            $image = Join-Path $linuxApp 'CraftOS-PC.x86_64.AppImage'
            $url = 'https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC.x86_64.AppImage'
            if (-not (Test-Path -LiteralPath $image)) {
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
            Push-Location $linuxApp
            try {
                & $image --appimage-extract
                if ($LASTEXITCODE -ne 0) { throw 'CraftOS-PC AppImage extract failed.' }
            } finally { Pop-Location }
        }
        & /bin/chmod +x $CraftOS
    } else {
        throw 'Set CRAFTOS_PC to CraftOS-PC_console.exe on Windows.'
    }
}
$CraftOS = (Resolve-Path -LiteralPath $CraftOS).Path
if (-not $romSource) { $romSource = Split-Path $CraftOS }
if ($OnLinux) {
    $env:SDL_AUDIODRIVER = 'dummy'
    $env:SDL_VIDEODRIVER = 'dummy'
}
$version = & $CraftOS --version | Select-Object -First 1
if ($version -ne 'CraftOS-PC v2.8.3') { throw "Unexpected CraftOS version: $version" }

$Source = (Resolve-Path -LiteralPath $Source).Path
$run = Join-Path $cache ('runs\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$run\config", "$run\rom" | Out-Null
Copy-Item -LiteralPath (Join-Path $romSource 'bios.lua'), (Join-Path $romSource 'rom') -Destination "$run\rom" -Recurse
$utf8 = New-Object System.Text.UTF8Encoding($false)
$config = @{
    standardsMode = $true; computerSpaceLimit = 1000000
    checkUpdates = $false; http_enable = $false
    keepOpenOnShutdown = $false; logErrors = $true
} | ConvertTo-Json
Write-SandboxText "$run\config\global.json" $config $utf8

$roles = @(
    @{ id = 0; args = 'server' },
    @{ id = 1; args = 'peer store' },
    @{ id = 2; args = 'peer store' },
    @{ id = 3; args = 'peer computer' }
)
foreach ($entry in $roles) {
    $disk = Join-Path (Join-Path $run 'computer') "$($entry.id)"
    New-Item -ItemType Directory -Force -Path "$disk\lib\stubs" | Out-Null
    foreach ($file in @('storage-peer.lua', 'tests\h4d-sandbox.lua')) {
        $from = Join-Path $Source ($file.Replace('\', [IO.Path]::DirectorySeparatorChar))
        $name = Split-Path $from -Leaf
        $code = [IO.File]::ReadAllText($from).Replace("`r`n", "`n")
        Write-SandboxText (Join-Path $disk $name) $code $utf8
    }
    $stub = Join-Path $Source 'lib/stubs/h4d_dep.lua'
    $stubCode = [IO.File]::ReadAllText($stub).Replace("`r`n", "`n")
    Write-SandboxText (Join-Path $disk 'lib/stubs/h4d_dep.lua') $stubCode $utf8
    $kind = if ($entry.id -eq 3) { 'computer' } elseif ($entry.id -eq 0) { 'server' } else { 'store' }
    Write-SandboxText (Join-Path $disk 'role.txt') $kind $utf8
    $bits = @("'h4d-sandbox.lua'") + @($entry.args.Split(' ') | ForEach-Object { "'" + $_ + "'" })
    $startup = "local ok, err = os.run({}, " + ($bits -join ', ') + ")`nif not ok then`n  local h = fs.open('sandbox-result.json', 'w')`n  if h then h.write(textutils.serializeJSON({ok=false,booted=false,errors={tostring(err)},lines={},capacity=fs.getCapacity('/')})) h.close() end`nend`nos.shutdown()"
    Write-SandboxText (Join-Path $disk 'startup.lua') $startup $utf8
}

Write-Output "Sandbox: h4d source=$Source disk=1000000"
Write-Output "Artifacts: $run"
$arguments = '--headless --directory "{0}" --rom "{1}" --id 0' -f $run, (Join-Path $run 'rom')
$stdout = ConvertTo-SandboxPath (Join-Path $run 'stdout.log')
$stderr = ConvertTo-SandboxPath (Join-Path $run 'stderr.log')
$process = Start-Process -FilePath $CraftOS -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
$resultPath = Join-Path (Join-Path (Join-Path $run 'computer') '0') 'sandbox-result.json'
do {
    if (Test-Path -LiteralPath $resultPath) { break }
    if ($process.HasExited) { break }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
$stderrText = ''
if (Test-Path -LiteralPath $stderr) { $stderrText = Get-Content -LiteralPath $stderr -Raw }
if ($stderrText) { Write-Output "Emulator stderr: $stderrText" }
if (-not (Test-Path -LiteralPath $resultPath)) {
    $tracePath = Join-Path (Split-Path $resultPath) 'sandbox-trace.txt'
    if (Test-Path -LiteralPath $tracePath) { Get-Content -LiteralPath $tracePath | ForEach-Object { Write-Output $_ } }
    if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Tail 20 | ForEach-Object { Write-Output $_ } }
    throw 'H4d sandbox produced no result.'
}
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
Write-Output ("server: ok={0} capacity={1} free={2}" -f $result.ok, $result.capacity, $result.free)
foreach ($line in @($result.lines)) { Write-Output "  $line" }
foreach ($errText in @($result.errors)) { if ($errText) { Write-Output "  error: $errText" } }
if ($stderrText) { throw 'CraftOS wrote to stderr.' }
if (-not $result.ok -or $result.capacity -ne 1000000 -or -not $result.cold -or -not $result.rereplicated -or -not $result.unknown) {
    throw 'H4d sandbox failed.'
}
Write-Output 'H4d sandbox passed.'
exit 0
