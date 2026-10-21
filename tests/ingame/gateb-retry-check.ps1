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
} finally {
    $server.Stop()
    $runspace.Close()
    $server.Dispose()
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
