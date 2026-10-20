param(
    [string]$Lua = 'C:\Tools\lua52\lua52.exe',
    [string]$Output = 'C:\Work\gemini-input\p3\evidence\wizard',
    [switch]$MockSuite
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path "$PSScriptRoot\..").Path
Push-Location $source
try {
    $files = @(Get-ChildItem "$source\tests\wh2-wizard-gate*" -File) +
        @(Get-ChildItem "$source\tests\sandbox\wh2-wizard*" -File) +
        @(Get-ChildItem "$source\tests\ingame\wh2-wizard*" -File) +
        @(Get-Item "$source\docs\evidence\wizard\README.md")
    foreach ($file in $files) {
        if ([IO.File]::ReadAllText($file.FullName) -match '(?m)[\t ]+\r?$') { throw "Trailing whitespace in $($file.Name)." }
    }
    foreach ($file in $files | Where-Object { $_.Extension -eq '.ps1' }) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count) { throw ($errors | ForEach-Object { $_.ToString() } | Out-String) }
    }
    foreach ($file in $files | Where-Object { $_.Extension -eq '.lua' }) {
        & $Lua -e ("assert(loadfile([[" + $file.FullName + "]]))")
        if ($LASTEXITCODE) { throw "Lua parse failed for $($file.Name)." }
    }
    $plan = Get-Content "$PSScriptRoot\wh2-wizard-gate-plan.json" -Raw | ConvertFrom-Json
    if ($plan.diskLimit -ne 1000000 -or $plan.soakSeconds -lt 7200 -or $plan.computers.turtles.Count -ne 4) { throw 'Scenario lost its mandatory scale.' }
    if (@($plan.requirements.id | Select-Object -Unique).Count -ne $plan.requirements.Count) { throw 'Requirement IDs must be unique.' }
    foreach ($row in $plan.requirements) {
        if (!$row.applies -and !$row.reason) { throw "Missing applicability reason for $($row.id)." }
        if ($row.applies -and !$row.evidence) { throw "Missing evidence requirement for $($row.id)." }
    }
    . "$PSScriptRoot\wh2-wizard-gate-host.ps1"
    $counts = ConvertFrom-WizardInventory 'Block has the following block data: [{Slot:0b,id:"superbwarfare:scheelite",count:64},{Slot:1b,Count:19b,id:"superbwarfare:scheelite"}]'
    if ($counts['superbwarfare:scheelite'] -ne 83) { throw 'Count parser lost a partial stack.' }
    if ((ConvertFrom-WizardInventory 'Block data: []').Count -ne 0) { throw 'Empty native inventory did not parse.' }
    foreach ($bad in @('No block entity was found', '[{Slot:0b,id:"minecraft:stone"}]',
        '[{Slot:0b,id:"minecraft:stone",count:64,components:{test:1}}]',
        '[{Slot:0b,id:"minecraft:stone",count:1},{Slot:0b,id:"minecraft:stone",count:1}]')) {
        $rejected = $false
        try { ConvertFrom-WizardInventory $bad | Out-Null } catch { $rejected = $true }
        if (!$rejected) { throw 'Malformed native inventory response was accepted.' }
    }
    New-Item -ItemType Directory -Force -Path $Output | Out-Null
    $log = Join-Path $Output ('selfcheck-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    & $Lua tests/wh2-wizard-gate-selfcheck.lua 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE) { throw 'Wizard scenario self-check failed.' }
    if ($MockSuite) {
        & $Lua tests/run.lua 2>&1 | Tee-Object -FilePath ($log.Replace('.txt','-mock-suite.txt'))
        if ($LASTEXITCODE) { throw 'Project mock suite failed.' }
    }
    Write-Output "Checked $($files.Count) owned files. Evidence: $log"
} finally { Pop-Location }
