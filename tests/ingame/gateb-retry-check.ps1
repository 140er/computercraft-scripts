$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\gateb-retry.ps1"

$downSec = 15
$budgetSec = 90
$root = Join-Path ([IO.Path]::GetTempPath()) "gateb-retry-check-$PID"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root | Out-Null
$log = Join-Path $root 'wait.log'
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()

$server = [powershell]::Create()
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$server.Runspace = $runspace
[void]$server.AddScript({
    param($Port, $DownSec)
    Start-Sleep -Seconds $DownSec
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $until = [DateTime]::UtcNow.AddSeconds(80)
    while (-not $listener.Pending()) {
        if ([DateTime]::UtcNow -gt $until) { $listener.Stop(); return }
        Start-Sleep -Milliseconds 100
    }
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $buf = New-Object byte[] 512
        [void]$stream.Read($buf, 0, $buf.Length)
        $body = '{"ok":true}'
        $payload = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
        $stream.Write($payload, 0, $payload.Length)
    } finally {
        $client.Close()
        $listener.Stop()
    }
}).AddArgument($port).AddArgument($downSec)
$handle = $server.BeginInvoke()

function Connect-GatebProbe([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $wait.AsyncWaitHandle.WaitOne(500)) { throw "connect timeout 127.0.0.1:$Port" }
        $client.EndConnect($wait)
        $stream = $client.GetStream()
        $req = [Text.Encoding]::ASCII.GetBytes("GET /health HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
        $stream.Write($req, 0, $req.Length)
        $buf = New-Object byte[] 512
        $read = $stream.Read($buf, 0, $buf.Length)
        $text = [Text.Encoding]::ASCII.GetString($buf, 0, $read)
        if ($text -notmatch '200') { throw "health reply was not 200: $text" }
        return @{ ok = $true }
    } finally { $client.Close() }
}

try {
    $health = Invoke-GatebRetry -BudgetSec $budgetSec -Log $log -Call { Connect-GatebProbe $port }
    if (-not $health.ok) { throw 'health call returned without ok' }
    $logged = Get-Content -LiteralPath $log -ErrorAction SilentlyContinue
    if (-not $logged -or -not ($logged -match 'waited')) { throw 'retry returned without logging a wait' }
    Write-Output "PASS gatebd retry waited out a ${downSec}s outage on 127.0.0.1:$port"

    $live = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $live.Start()
    $livePort = ([Net.IPEndPoint]$live.LocalEndpoint).Port
    $liveScript = [powershell]::Create()
    $liveSpace = [runspacefactory]::CreateRunspace()
    $liveSpace.Open()
    $liveScript.Runspace = $liveSpace
    [void]$liveScript.AddScript({
        param($Listener)
        $client = $Listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $buf = New-Object byte[] 512
            [void]$stream.Read($buf, 0, $buf.Length)
            $body = '{"ok":true,"hold":false}'
            $payload = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
            $stream.Write($payload, 0, $payload.Length)
        } finally { $client.Close(); $Listener.Stop() }
    }).AddArgument($live)
    $liveHandle = $liveScript.BeginInvoke()
    $script:GatebUrl = "http://127.0.0.1:$livePort"
    $script:GatebToken = 'test-token'
    $script:rawCalls = 0
    function Invoke-Gateb {
        param([string]$Method, [string]$Path, $Body = $null, [string]$OutFile = $null, [switch]$Raw, [switch]$AllowMissing)
        $script:rawCalls++
        if ($script:rawCalls -lt 2) { throw 'raw client down' }
        return @{ via = 'raw'; path = $Path }
    }
    Install-GatebRetry (Join-Path $root 'wrap.log')
    $wrapped = Invoke-Gateb GET '/health'
    if (-not $wrapped.ok) { throw 'wrapped health call did not return ok' }
    if ($script:rawCalls -ne 0) { throw 'health retry used the raw client' }
    $other = Invoke-Gateb GET '/runs/1'
    if ($other.via -ne 'raw' -or $script:rawCalls -lt 2) { throw 'non-health gatebd call was not retried' }
    $wrapLog = Get-Content -LiteralPath (Join-Path $root 'wrap.log')
    if (-not ($wrapLog -match 'waited')) { throw 'wrapped retry did not log the wait' }
    Write-Output 'PASS wrapped gatebd calls retry, and health uses the short client'
} finally {
    if ($liveScript) { $liveScript.Stop(); $liveSpace.Close(); $liveScript.Dispose() }
    $server.Stop()
    $runspace.Close()
    $server.Dispose()
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
