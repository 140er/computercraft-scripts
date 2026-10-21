$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\turnon-loaded.ps1"

function Assert-Stays([scriptblock]$Send, [string]$Label) {
    $released = $false
    try {
        Wait-ChunkNotFull -Send $Send -Seconds 0 | Out-Null
        $released = $true
    } catch {
        if ($_.Exception.Message -notmatch 'stayed loaded') { throw }
    }
    if ($released) { throw "Wait released on $Label." }
}

$seen = New-Object Collections.Generic.List[string]
Assert-Stays { param($Command) $seen.Add($Command); return '' } 'one empty reply'
if ($seen.Count -ne 1 -or $seen[0] -ne 'data get block 32 66 4') { throw "Probe was [$($seen -join ', ')]." }

Assert-Stays { param($Command) return 'That position is not loaded' } 'one not-loaded reply'
Assert-Stays { param($Command) return 'The target block is not a block entity' } 'a loaded non-entity block'

$state = @{ n = 0 }
$reply = Wait-ChunkNotFull -Send {
    param($Command)
    $state.n++
    if ($Command -ne 'data get block 32 66 4') { throw "Probe was $Command." }
    switch ($state.n) {
        1 { return '' }
        2 { return 'That position is not loaded' }
        3 { return 'The target block is not a block entity' }
        default { return 'That position is not loaded' }
    }
} -Seconds 30 -IntervalSec 0
if ($reply -notmatch 'position is not loaded') { throw "Released on [$reply]." }
if ($state.n -ne 5) { throw "Released after $($state.n) replies." }

Write-Output 'PASS unload wait needs two not-loaded replies and ignores one empty reply'
