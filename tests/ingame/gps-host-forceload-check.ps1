$ErrorActionPreference = 'Stop'
$text = [IO.File]::ReadAllText("$PSScriptRoot\run.ps1")
$mark = "Start-TestServer 'loader-resume'"
$at = $text.IndexOf($mark)
if ($at -lt 0) { throw 'run.ps1 has no loader-resume start' }
$before = $text.Substring(0, $at)
$after = $text.Substring($at)
$release = $after.IndexOf('boot-hold')
if ($release -lt 0) { throw 'loader-resume never releases boot-hold' }
$window = $after.Substring(0, $release)

function Get-Chunk([int]$Block) { [int][Math]::Floor($Block / 16.0) }
if ((Get-Chunk -16) -ne -1 -or (Get-Chunk 16) -ne 1 -or (Get-Chunk 31) -ne 1 -or (Get-Chunk 0) -ne 0) {
    throw 'chunk math does not match the server forceload replies'
}

function Update-Forceload($Set, [string]$Region) {
    foreach ($line in ($Region -split "`n")) {
        if ($line -match 'the_nether') { continue }
        if ($line -notmatch 'forceload (add|remove) (-?\d+) (-?\d+) (-?\d+) (-?\d+)') { continue }
        $op = $Matches[1]
        $x1 = Get-Chunk ([int]$Matches[2]); $z1 = Get-Chunk ([int]$Matches[3])
        $x2 = Get-Chunk ([int]$Matches[4]); $z2 = Get-Chunk ([int]$Matches[5])
        if ($x1 -gt $x2) { $swap = $x1; $x1 = $x2; $x2 = $swap }
        if ($z1 -gt $z2) { $swap = $z1; $z1 = $z2; $z2 = $swap }
        for ($x = $x1; $x -le $x2; $x++) {
            for ($z = $z1; $z -le $z2; $z++) {
                $key = "$x,$z"
                if ($op -eq 'add') { $Set[$key] = $true } else { [void]$Set.Remove($key) }
            }
        }
    }
}

$loaded = @{}
Update-Forceload $loaded $before
Update-Forceload $loaded $window
$hosts = @(@(-6, -6), @(6, -6), @(-6, 6))
$missing = @()
foreach ($point in $hosts) {
    $key = "$(Get-Chunk $point[0]),$(Get-Chunk $point[1])"
    if (-not $loaded.ContainsKey($key)) { $missing += "$($point[0]),$($point[1]) chunk $key" }
}
if ($missing.Count -gt 0) { throw "GPS hosts are not force-loaded before resume locate: $($missing -join '; ')" }
if ($window -notmatch '/4') { throw 'resume turns GPS hosts on without checking that 4 computers were loaded' }
Write-Output 'PASS resume forceload covers the GPS hosts and checks that 4 computers loaded'
