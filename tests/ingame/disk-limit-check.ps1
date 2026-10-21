$ErrorActionPreference = 'Stop'
$run = [IO.File]::ReadAllText("$PSScriptRoot\run.ps1")
$gate = [IO.File]::ReadAllText("$PSScriptRoot\gateb.ps1")
if ($run -notmatch '\[int\]\$SpaceLimit = 1000000,') { throw 'SpaceLimit default is not 1000000' }
if ($run -notmatch '\$diskLimit = 1000000') { throw 'diskLimit is not 1000000' }
if ($run -match '8000000|4000000') { throw 'run.ps1 still names a disk limit other than 1000000' }
if ($gate -match '8000000|4000000') { throw 'gateb.ps1 still names a disk limit other than 1000000' }
Write-Output 'PASS gate B disk limit defaults to 1000000'
