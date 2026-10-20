param(
    [string]$Output = 'C:\Work\gemini-input\p3\evidence\wizard',
    [string]$Bindings = (Join-Path $PSScriptRoot '..\wh2-wizard-gate-bindings.lua'),
    [string]$CraftOS = $env:CRAFTOS_PC,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path "$PSScriptRoot\..\..").Path
& "$source\tests\ingame\wh2-wizard.ps1" -Mode Prepare -Output "$Output\gate-a-preparation" -Bindings $Bindings
if ($PrepareOnly) { return }
$arguments = @{Scenario='wh2-wizard'; DiskLimit=1000000; Output="$Output\gate-a"; DataRoot="$Output\gate-a-data"; Seconds=900}
if ($CraftOS) { $arguments.CraftOS = $CraftOS }
$previousBindings = $env:WH2_WIZARD_GATE_BINDINGS
$env:WH2_WIZARD_GATE_BINDINGS = [IO.Path]::GetFullPath($Bindings)
try { & "$PSScriptRoot\run.ps1" @arguments; $runExit = $LASTEXITCODE }
finally { $env:WH2_WIZARD_GATE_BINDINGS = $previousBindings }
exit $runExit
