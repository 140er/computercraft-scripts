$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$utf8 = New-Object Text.UTF8Encoding($false)
. "$PSScriptRoot\role-closure.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) 'verify-source-check'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
$computers = Join-Path $root 'computers'
$out = Join-Path $root 'out'
New-Item -ItemType Directory -Path $computers, $out | Out-Null
foreach ($id in @(0, 1)) {
    $disk = Join-Path $computers "$id"
    New-Item -ItemType Directory -Path $disk | Out-Null
    $entries = Get-GateEntries $source 'mining' $id
    Write-GateRoleFiles -Disk $disk -Source $source -Entry $entries -Utf8 $utf8 | Out-Null
}
if (Test-Path (Join-Path $computers '0\nav.lua')) { throw 'The server role closure includes nav.lua, so this check no longer targets the old failure.' }
& "$PSScriptRoot\verify-source.ps1" -Computers $computers -Output $out -Ids @(0, 1) -Scenario mining
$atomic = Join-Path $computers '0\atomic.lua'
$text = [IO.File]::ReadAllText($atomic)
[IO.File]::WriteAllText($atomic, ($text + "`n-- tampered`n"), $utf8)
$failed = $false
try { & "$PSScriptRoot\verify-source.ps1" -Computers $computers -Output $out -Ids @(0) -Scenario mining } catch { $failed = $true }
if (-not $failed) { throw 'A tampered atomic.lua was accepted.' }
Write-Output 'PASS verify-source checks each computer against its role closure'
