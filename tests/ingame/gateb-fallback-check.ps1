$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "gateb-fallback-check-$PID"
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root | Out-Null
$log = Join-Path $root 'wait.log'
$hold = Join-Path $root 'gateB.hold'
$lock = Join-Path $root 'gateB.lock'
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()
$serverJob = $null

$job = Start-Job -ScriptBlock {
    param($Module, $Port, $Log, $Hold, $Lock, $Root)
    $ErrorActionPreference = 'Stop'
    . $Module
    $script:GatebUrl = "http://127.0.0.1:$Port"
    $script:GatebToken = 'fallback-check'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $slot = Complete-GatebFallback -HoldFile $Hold -LockDir $Lock -Owner 'gateb-fallback-check' -Log $Log -TakeLock
        $sw.Stop()
        $hold2 = Join-Path $Root 'held.hold'
        $lock2 = Join-Path $Root 'held.lock'
        [IO.File]::WriteAllText($hold2, 'held')
        $blocked = Complete-GatebFallback -HoldFile $hold2 -LockDir $lock2 -Owner 'gateb-fallback-check' -Log $Log -TakeLock
        [pscustomobject]@{
            Ok = $true
            Source = [string]$slot.Source
            Sec = [int]$sw.Elapsed.TotalSeconds
            Error = ''
            Blocked = [bool]$blocked.Held
            Lock2 = [bool](Test-Path -LiteralPath $lock2)
        }
    } catch {
        $sw.Stop()
        [pscustomobject]@{ Ok = $false; Source = ''; Sec = [int]$sw.Elapsed.TotalSeconds; Error = $_.Exception.Message; Blocked = $false; Lock2 = $false }
    }
} -ArgumentList "$PSScriptRoot\gateb-retry.ps1", $port, $log, $hold, $lock, $root

try {
    $done = Wait-Job $job -Timeout 180
    if ($job.State -ne 'Completed') {
        Stop-Job $job
        throw 'gatebd retry still waiting after 180s, which is the 20 minute budget'
    }
    $slot = Receive-Job $job
    if ($slot.Error) { throw "scenario ERROR. $($slot.Error)" }
    if ($slot.Sec -gt 150) { throw "fallback took $($slot.Sec)s, past about 2 minutes" }
    $logged = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Where-Object { $_ -eq 'gatebd unavailable, using VM locks' })
    if ($logged.Count -ne 1) { throw "fallback log count is $($logged.Count)" }
    if ($slot.Source -ne 'vm') { throw "gate path is $($slot.Source)" }
    if (-not (Test-Path -LiteralPath "$lock\owner.txt")) { throw 'VM lock was not taken' }
    if (-not $slot.Blocked) { throw 'VM hold file did not block' }
    if ($slot.Lock2) { throw 'VM lock was taken while the hold file exists' }

    $answerLog = Join-Path $root 'answer.log'
    $answerLock = Join-Path $root 'answer.lock'
    $answerHold = Join-Path $root 'answer.hold'
    $portFile = Join-Path $root 'answer.port'
    $serverJob = Start-Job -ScriptBlock {
        param($PortFile)
        $ErrorActionPreference = 'Stop'
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        [IO.File]::WriteAllText($PortFile, ([Net.IPEndPoint]$listener.LocalEndpoint).Port)
        function Serve([string]$Body) {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $buf = New-Object byte[] 1024
                [void]$stream.Read($buf, 0, $buf.Length)
                $bytes = [Text.Encoding]::ASCII.GetBytes($Body)
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $client.Close() }
        }
        Serve '{"ok":true,"hold":false}'
        Serve '{"ok":true,"hold":true}'
    } -ArgumentList $portFile
    $portDeadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $portFile)) {
        if ([DateTime]::UtcNow -gt $portDeadline) { throw 'gatebd answer listener did not start' }
        Start-Sleep -Milliseconds 200
    }
    . "$PSScriptRoot\gateb-retry.ps1"
    $script:GatebUrl = 'http://127.0.0.1:' + (Get-Content -LiteralPath $portFile -Raw).Trim()
    $script:GatebToken = 'fallback-check'
    $open = Complete-GatebFallback -HoldFile $answerHold -LockDir $answerLock -Owner 'gateb-fallback-check' -Log $answerLog -TakeLock
    $shut = Complete-GatebFallback -HoldFile $answerHold -LockDir $answerLock -Owner 'gateb-fallback-check' -Log $answerLog -TakeLock
    if ($open.Source -ne 'gatebd' -or $open.Held) { throw "gatebd answer took path $($open.Source) held $($open.Held)" }
    if ($shut.Source -ne 'gatebd' -or -not $shut.Held) { throw "gatebd hold took path $($shut.Source) held $($shut.Held)" }
    if (Test-Path -LiteralPath $answerLock) { throw 'VM lock was taken while gatebd answered' }
    $answerLines = @(Get-Content -LiteralPath $answerLog -ErrorAction SilentlyContinue | Where-Object { $_ -eq 'gatebd unavailable, using VM locks' })
    if ($answerLines.Count -ne 0) { throw 'gatebd answer logged the VM lock fallback' }
    Write-Output "PASS dead gatebd fell back in $($slot.Sec)s and took the VM lock. A VM hold file blocked the next take."
} finally {
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($serverJob) { Stop-Job $serverJob -ErrorAction SilentlyContinue; Remove-Job $serverJob -Force -ErrorAction SilentlyContinue }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
