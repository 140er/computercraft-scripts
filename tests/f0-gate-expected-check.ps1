$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$lua = 'C:\Tools\lua52\lua52.exe'
if (!(Test-Path -LiteralPath $lua)) { throw 'lua52 missing' }
Set-Location $repo
$utf8 = New-Object Text.UTF8Encoding $false
$note = 'hub.lua:29 makes the hub carry miner.lua and all of ssot.lua, and F2h owns the fix, not PR 103.'

function Reset-Dir([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path | Out-Null
}
function Add-Result([string]$Root, [int]$Id) {
    $dir = Join-Path $Root "computers\$Id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText("$dir\sandbox-result.json", '{"ok":true}', $utf8)
}
function Add-Bytes([string]$Root, [int]$Id, [int64]$Bytes) {
    $dir = Join-Path $Root "computers\$Id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stream = [IO.File]::Open("$dir\payload.bin", 'Create')
    try { $stream.SetLength($Bytes) } finally { $stream.Dispose() }
}
function Add-Verdict([string]$Root, [int]$Id) {
    $text = "FAIL`nCannot find path 'C:\Work\mc-ssot-pr1-example\world\computercraft\computer\$Id\sandbox-result.json' because it does not exist.`n"
    [IO.File]::WriteAllText("$Root\verdict.txt", $text, $utf8)
}
function Invoke-Done([string]$Root, [string]$Scenario) {
    $out = & $lua tests\f0-role-load.lua --gate $Root $Scenario 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out }
}
function Format-Result($Result) {
    $text = $Result.Text.Trim()
    if ($text.Length -gt 500) { return "exit $($Result.Code)`n$($text.Substring(0, 500))`n..." }
    return "exit $($Result.Code)`n$text"
}
function Assert-Accepted($Result) {
    $lines = @($Result.Text -split "`r?`n" | Where-Object { $_ -ne '' })
    $hit = @($lines | Where-Object { $_ -eq 'gate mining EXPECTED' })
    $noted = @($lines | Where-Object { $_ -eq $note })
    if ($Result.Code -ne 0 -or $hit.Count -ne 1 -or $noted.Count -ne 1) {
        throw "overflow was not accepted`n$(Format-Result $Result)"
    }
}
function Assert-Rejected($Result, [string]$Label) {
    $lines = @($Result.Text -split "`r?`n")
    $hit = @($lines | Where-Object { $_ -eq 'gate mining EXPECTED' })
    if ($Result.Code -eq 0 -or $hit.Count -ne 0) {
        throw "$Label was accepted`n$(Format-Result $Result)"
    }
}

$base = Join-Path $env:TEMP 'f0-gate-expected-check'
$overflow = Join-Path $base 'overflow'
Reset-Dir $overflow
foreach ($id in 0, 1, 2, 3, 4) { Add-Result $overflow $id }
Add-Bytes $overflow 6 1000001
Add-Verdict $overflow 6

$other = Join-Path $base 'computer0'
Reset-Dir $other
foreach ($id in 1, 2, 3, 4, 6) { Add-Result $other $id }
Add-Verdict $other 0

$limit = Join-Path $base 'at-limit'
Reset-Dir $limit
foreach ($id in 0, 1, 2, 3, 4) { Add-Result $limit $id }
Add-Bytes $limit 6 1000000
Add-Verdict $limit 6

$both = Join-Path $base 'both'
Reset-Dir $both
foreach ($id in 1, 2, 3, 4) { Add-Result $both $id }
Add-Bytes $both 6 1000001
Add-Verdict $both 6

Assert-Accepted (Invoke-Done $overflow 'mining')
Assert-Rejected (Invoke-Done $other 'mining') 'computer 0 missing its result'
Assert-Rejected (Invoke-Done $limit 'mining') 'computer 6 at 1000000 bytes'
Assert-Rejected (Invoke-Done $both 'mining') 'computer 0 and computer 6 both missing'
Assert-Rejected (Invoke-Done $overflow 'warehouse') 'warehouse'
Write-Output 'PASS overflow accepted and a different mining fail rejected'
