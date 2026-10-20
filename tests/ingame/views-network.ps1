param(
  [Parameter(Mandatory=$true)][ValidateSet('Start','Stop')][string]$Action,
  [Parameter(Mandatory=$true)][int]$ServerPid,
  [Parameter(Mandatory=$true)][string]$TestRoot,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [string]$JavaBin = 'C:\Tools\jdk-21\bin'
)
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
if ($rootPath -notmatch '^C:\\Work\\mc-ssot-pr5-[^\\]+$') { throw 'Expected the owned PR5 disposable test root.' }
$processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ServerPid"
if (-not $processInfo -or $processInfo.Name -notmatch '^java(w)?\.exe$') { throw 'The supplied PID is not a Java process.' }
if ($processInfo.CommandLine -notlike "*$rootPath*") { throw 'The supplied Java command line does not identify the owned PR5 test root.' }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$settingsPath = Join-Path $outputPath 'views-network.jfc'
$recordingPath = Join-Path $outputPath 'views-network.jfr'
$statePath = Join-Path $outputPath 'views-network-state.json'
$jcmd = Join-Path $JavaBin 'jcmd.exe'
$jfr = Join-Path $JavaBin 'jfr.exe'
if ($Action -eq 'Start') {
  if (Test-Path -LiteralPath $statePath) { throw 'A network recording state already exists in this directory.' }
  @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration version="2.0" label="PR5 server loopback writes" description="Socket writes during the views acceptance run" provider="PR5">
  <event name="jdk.SocketWrite">
    <setting name="enabled">true</setting>
    <setting name="threshold">0 ms</setting>
    <setting name="stackTrace">false</setting>
  </event>
</configuration>
'@ | Set-Content -LiteralPath $settingsPath -Encoding UTF8
  $startOutput = & $jcmd $ServerPid 'JFR.start' 'name=pr5views' "settings=$settingsPath" 2>&1
  $startOutput | Set-Content -LiteralPath (Join-Path $outputPath 'views-network-start.txt')
  if ($LASTEXITCODE -ne 0) { throw 'JFR.start failed. Read views-network-start.txt.' }
  @{pid=$ServerPid;root=$rootPath;startedUtc=[DateTime]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content -LiteralPath $statePath
  Write-Output "Started PR5 socket recording for PID $ServerPid."
  return
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.pid -ne $ServerPid -or $state.root -ne $rootPath) { throw 'The recording state belongs to a different process or test root.' }
$stopOutput = & $jcmd $ServerPid 'JFR.stop' 'name=pr5views' "filename=$recordingPath" 2>&1
$stopOutput | Set-Content -LiteralPath (Join-Path $outputPath 'views-network-stop.txt')
if ($LASTEXITCODE -ne 0) { throw 'JFR.stop failed. Read views-network-stop.txt.' }
$stoppedUtc = [DateTime]::UtcNow
$rawPath = Join-Path $outputPath 'views-network-events.json'
& $jfr print --json --events jdk.SocketWrite $recordingPath |
  Set-Content -LiteralPath $rawPath -Encoding UTF8
if ($LASTEXITCODE -ne 0) { throw 'jfr print failed.' }
$raw = Get-Content -LiteralPath $rawPath -Raw | ConvertFrom-Json
$events = @($raw.recording.events | Where-Object { $null -ne $_ })
$loopback = @($events | Where-Object {
  $_.values.address -eq '127.0.0.1' -or $_.values.address -eq '::1' -or $_.values.address -eq '0:0:0:0:0:0:0:1'
})
$bytes = ($loopback | ForEach-Object { [long]$_.values.bytesWritten } | Measure-Object -Sum).Sum
$elapsed = ($stoppedUtc - [DateTime]::Parse($state.startedUtc)).TotalSeconds
$summary = [ordered]@{
  measured = $loopback.Count -gt 0
  scope = 'Owned Minecraft server JVM loopback TCP writes, including RCON and other localhost clients. Not GPU-only.'
  pid = $ServerPid
  startedUtc = $state.startedUtc
  stoppedUtc = $stoppedUtc.ToString('o')
  elapsedSeconds = $elapsed
  socketWriteEvents = $events.Count
  loopbackWriteEvents = $loopback.Count
  loopbackBytesWritten = $(if ($loopback.Count -gt 0) { [long]$bytes } else { $null })
  loopbackBytesPerSecond = $(if ($loopback.Count -gt 0 -and $elapsed -gt 0) { [math]::Round($bytes / $elapsed,2) } else { $null })
  limitation = $(if ($loopback.Count -eq 0) { 'No loopback SocketWrite events were emitted. Netty native or NIO writes may bypass this JFR event. A zero-byte result is not asserted.' } else { 'Includes protocol overhead and all captured localhost sockets. Events are outbound server writes only.' })
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputPath 'views-network-summary.json')
$summary | ConvertTo-Json
