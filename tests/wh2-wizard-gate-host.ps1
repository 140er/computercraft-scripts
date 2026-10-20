function ConvertFrom-WizardInventory([string]$Text) {
    $payload = [regex]::Match($Text, '(\[[\s\S]*\])\s*$')
    if (!$payload.Success) { throw 'Inventory response has no native Items list.' }
    $list = $payload.Groups[1].Value
    if ($list -match '^\[\s*\]$') { return @{} }
    $rows = [regex]::Matches($list, '\{[^{}]*\}')
    if (!$rows.Count -or $list -notmatch '^\[\s*\{[^{}]+\}(\s*,\s*\{[^{}]+\})*\s*\]$') { throw 'Inventory parser requires the component-free seeded load. Use the native inventory API for components.' }
    $counts = @{}; $slots = @{}
    foreach ($row in $rows) {
        $item = [regex]::Match($row.Value, 'id\s*:\s*["'']([a-z0-9_.-]+:[a-z0-9_/.-]+)["'']')
        $amount = [regex]::Match($row.Value, '(?i)count\s*:\s*(\d+)b?')
        $slot = [regex]::Match($row.Value, 'Slot\s*:\s*(\d+)b?')
        if (!$item.Success -or !$amount.Success -or !$slot.Success) { throw 'Inventory entry omitted its slot, ID, or count.' }
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
