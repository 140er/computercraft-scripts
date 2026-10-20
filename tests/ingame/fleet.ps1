param(
    [string]$Output='C:\Work\gemini-input\p3\evidence\fleet\gateB',
    [string]$TestRoot='',
    [switch]$PrepareOnly,
    [switch]$Client
)
$ErrorActionPreference='Stop'
$fleetLock='C:\Work\gemini-input\p2\gateB.lock'
if (!$TestRoot) { $TestRoot='C:\Work\mc-wh2-fleet-'+[guid]::NewGuid().ToString('N').Substring(0,8) }
if ($PrepareOnly) {
    & "$PSScriptRoot\run.ps1" -Fleet -Scenario warehouse -TestRoot $TestRoot -Output $Output -PrepareOnly
    return
}
if (!(Test-Path -LiteralPath "$TestRoot\server.properties")) {
    & "$PSScriptRoot\run.ps1" -Fleet -Scenario warehouse -TestRoot $TestRoot -Output $Output -PrepareOnly
}
$fleetDeadline=[DateTime]::UtcNow.AddHours(10)
$fleetHeld=$false
try {
    while (!$fleetHeld) {
        if ([DateTime]::UtcNow -ge $fleetDeadline) { throw 'Gate B lock wait exceeded ten hours' }
        $fleetFree=(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1KB
        if ($fleetFree -ge 5GB) {
            try {
                New-Item -ItemType Directory -Path $fleetLock -ErrorAction Stop | Out-Null
                $fleetHeld=$true
                [IO.File]::WriteAllText("$fleetLock\owner.txt",'fleet')
            } catch {
                if (!(Test-Path -LiteralPath $fleetLock)) { throw }
            }
        }
        if (!$fleetHeld) { Start-Sleep -Seconds 60 }
    }
    & "$PSScriptRoot\run.ps1" -Fleet -Prepared -Scenario warehouse -TestRoot $TestRoot -Output $Output -Client:$Client
} finally {
    if ($fleetHeld) {
        $fleetOwner=Get-Content -LiteralPath "$fleetLock\owner.txt" -Raw
        if ($fleetOwner -eq 'fleet') {
            Remove-Item -LiteralPath "$fleetLock\owner.txt"
            Remove-Item -LiteralPath $fleetLock
        }
    }
}
