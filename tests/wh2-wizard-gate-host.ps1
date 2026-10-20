function ConvertFrom-WizardInventory([string]$Text) {
    $payload = [regex]::Match($Text, '(\[[\s\S]*\])\s*$')
    if (!$payload.Success) { throw 'Inventory response has no native Items list.' }
    $list = $payload.Groups[1].Value
    if ($list -match '^\[\s*\]$') { return @{} }
    $rows = [regex]::Matches($list, '\{[^{}]*\}')
    if (!$rows.Count -or $list -notmatch '^\[\s*\{[^{}]+\}(\s*,\s*\{[^{}]+\})*\s*\]$') { throw 'Inventory parser requires the component-free seeded load. Use the native inventory API for components.' }
    $counts = @{}; $slots = @{}
    foreach ($row in $rows) {
        $fields = $row.Value.Trim('{}').Split(',')
        if ($fields.Count -ne 3) { throw 'Inventory entry must contain exactly its slot, ID, and count.' }
        $item = [regex]::Match($row.Value, '(?:\{|,)\s*id\s*:\s*["'']([a-z0-9_.-]+:[a-z0-9_/.-]+)["'']\s*(?=,|\})')
        $amount = [regex]::Match($row.Value, '(?:\{|,)\s*(?:count|Count)\s*:\s*(\d+)b?\s*(?=,|\})')
        $slot = [regex]::Match($row.Value, '(?:\{|,)\s*Slot\s*:\s*(\d+)b?\s*(?=,|\})')
        if (!$item.Success -or !$amount.Success -or !$slot.Success) { throw 'Inventory entry omitted a valid slot, ID, or count.' }
        $number = [int]$slot.Groups[1].Value
        if ($number -gt 26 -or $slots.ContainsKey($number)) { throw 'Inventory response has an invalid or duplicate slot.' }
        $slots[$number] = $true
        $quantity = [int]$amount.Groups[1].Value
        if ($quantity -lt 1 -or $quantity -gt 64) { throw 'Inventory count is outside the seeded stack limits.' }
        $key = $item.Groups[1].Value
        $counts[$key] = [int]$counts[$key] + $quantity
    }
    return $counts
}

function Get-WizardGateFiles([string]$Source, [ValidateSet('server','client')][string]$Role) {
    $path = Join-Path $Source 'tests\wh2-wizard-gate-prerequisites.json'
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1) { throw 'Unknown wizard prerequisite manifest version.' }
    $names = @($manifest.roles.$Role) + @('atomic.lua','ssot.lua','ssot-client.lua','mine-tasks.lua',
        'warehouse-tasks.lua','wh2-wizard.lua','wh2-board.lua','wh2-wizard-adapter.lua','wh2-wizard-host.lua')
    foreach ($name in ($names | Sort-Object -Unique)) {
        if ($name -match '(^|[\\/])\.\.([\\/]|$)|^[\\/]|:') { throw 'Prerequisite path must stay inside the repository.' }
        $candidate = Join-Path $Source $name
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            Get-ChildItem -LiteralPath $candidate -File -Recurse | ForEach-Object { $_.FullName.Substring($Source.TrimEnd('\','/').Length + 1) }
        } else { $name }
    }
}

function Get-WizardGateMissing([string]$Source, [ValidateSet('server','client')][string]$Role, [string]$Bindings) {
    foreach ($name in @(Get-WizardGateFiles $Source $Role)) {
        if (!(Test-Path -LiteralPath (Join-Path $Source $name))) { $name }
    }
    if (!$Bindings -or !(Test-Path -LiteralPath $Bindings -PathType Leaf)) { 'wh2-wizard-gate-bindings.lua' }
}
