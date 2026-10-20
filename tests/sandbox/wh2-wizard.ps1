param(
    [string]$Output = 'C:\Work\gemini-input\p3\evidence\wizard',
    [string]$Bindings = '',
    [string]$CraftOS = $env:CRAFTOS_PC,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path "$PSScriptRoot\..\..").Path
& "$source\tests\ingame\wh2-wizard.ps1" -Mode Prepare -Output "$Output\gate-a-preparation" -Bindings $Bindings
if ($PrepareOnly) { return }
if (!$Bindings -or !(Test-Path -LiteralPath $Bindings)) { throw 'Gate A needs authenticated wizard test bindings. The legacy transport is forbidden.' }
$runner = [IO.File]::ReadAllText("$PSScriptRoot\run.ps1")
if ($runner -notmatch "'wh2-wizard'") { throw 'The lead must integrate wh2-wizard dispatch in tests/sandbox/run.ps1 before Gate A can run.' }
$arguments = @{Scenario='wh2-wizard'; DiskLimit=1000000; Output="$Output\gate-a"; DataRoot="$Output\gate-a-data"; Seconds=900}
if ($CraftOS) { $arguments.CraftOS = $CraftOS }
$env:WH2_WIZARD_GATE_BINDINGS = (Resolve-Path -LiteralPath $Bindings).Path
try { & "$PSScriptRoot\run.ps1" @arguments }
finally { Remove-Item Env:\WH2_WIZARD_GATE_BINDINGS }
