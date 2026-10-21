# A fresh store role on a 1000000-byte CraftOS-PC disk must name its setup command and return.
param(
    [string]$CraftOS = $env:CRAFTOS_PC,
    [string]$Source = (Resolve-Path "$PSScriptRoot\..").Path,
    [int]$Seconds = 40
)
$ErrorActionPreference = 'Stop'
$OnLinux = $false
if ($PSVersionTable.PSVersion.Major -ge 6) { $OnLinux = $IsLinux -eq $true }

function ConvertTo-SandboxPath([string]$Path) {
    if ($script:OnLinux) { return $Path.Replace('\', '/') }
    return $Path
}
function Write-SandboxText([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
    $dir = Split-Path $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
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
    if ($OnLinux) { throw 'Set CRAFTOS_PC to the CraftOS-PC 2.8.3 AppRun.' }
    $app = Join-Path $cache 'craftos-2.8.3'
    $CraftOS = Join-Path $app 'CraftOS-PC_console.exe'
    if (-not (Test-Path -LiteralPath $CraftOS)) {
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $zip = Join-Path $cache 'craftos-2.8.3.zip'
        $url = 'https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC-Portable-Win64.zip'
        Invoke-WebRequest -UseBasicParsing $url -OutFile $zip
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne 'caf74fa9d6fcce44c940bf77ff789378fa34a4ebb0b608c57f885a0b0aebac37') {
            throw 'CraftOS-PC archive checksum mismatch.'
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $app -Force
    }
}
$CraftOS = (Resolve-Path -LiteralPath $CraftOS).Path
if (-not $romSource) { $romSource = Split-Path $CraftOS }
$version = & $CraftOS --version | Select-Object -First 1
if ($version -ne 'CraftOS-PC v2.8.3') { throw "Use CraftOS-PC v2.8.3. Got: $version" }

$Source = (Resolve-Path -LiteralPath $Source).Path
$lua = 'C:\Tools\lua52\lua52.exe'
if (-not (Test-Path -LiteralPath $lua)) { $lua = 'lua5.2' }
$root = $Source.Replace('\', '/')
$files = & $lua -e "local m=dofile('$root/bundle-manifest.lua'); for _,f in ipairs(m.roles.store.files) do print(f) end"
if ($LASTEXITCODE -ne 0 -or -not $files) { throw 'Cannot list the store role files.' }

$run = Join-Path $cache ('runs\store-boot-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$run\config", "$run\rom", "$run\computer\0" | Out-Null
Copy-Item -LiteralPath (Join-Path $romSource 'bios.lua'), (Join-Path $romSource 'rom') -Destination "$run\rom" -Recurse
$utf8 = New-Object System.Text.UTF8Encoding($false)
$config = @{
    standardsMode = $true; computerSpaceLimit = 1000000
    checkUpdates = $false; http_enable = $false
    keepOpenOnShutdown = $false; logErrors = $true
} | ConvertTo-Json
Write-SandboxText "$run\config\global.json" $config $utf8
$disk = Join-Path $run 'computer\0'
foreach ($file in @($files)) {
    if (-not $file) { continue }
    $from = Join-Path $Source ($file.Replace('/', '\'))
    $code = [IO.File]::ReadAllText($from).Replace("`r`n", "`n")
    Write-SandboxText (Join-Path $disk ($file.Replace('/', '\'))) $code $utf8
}
$boot = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'store-boot.lua')).Replace("`r`n", "`n")
Write-SandboxText (Join-Path $disk 'startup.lua') $boot $utf8

$arguments = '--headless --directory "{0}" --rom "{1}" --id 0' -f $run, (Join-Path $run 'rom')
$stdout = Join-Path $run 'stdout.log'
$stderr = Join-Path $run 'stderr.log'
$process = Start-Process -FilePath $CraftOS -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$resultPath = Join-Path $disk 'store-boot-result.txt'
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
do {
    if (Test-Path -LiteralPath $resultPath) { break }
    if ($process.HasExited) { break }
    Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
if (-not (Test-Path -LiteralPath $resultPath)) {
    if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Tail 30 }
    throw 'Store boot produced no result.'
}
$text = [IO.File]::ReadAllText($resultPath)
if ($text -notmatch 'capacity 1000000') { throw "capacity was not 1000000`n$text" }
if ($text -match 'Type an answer and press enter') { throw "fresh store waited for setup input`n$text" }
if ($text -notmatch 'returned true') { throw "fresh store did not return`n$text" }
if ($text -notmatch 'store server') { throw "fresh store did not name the setup command`n$text" }
Write-Output 'PASS fresh store names store server and does not wait for input'
exit 0
