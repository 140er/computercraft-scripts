function Read-Owner([int]$Id) {
    $path="$TestRoot\world\computercraft\computer\$Id\ar-owner.json"
    if (!(Test-Path $path)) { return $null }
    try { $state=Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $state -or $null -eq $state.ok) { return $null }
    if (!$state.ok) { throw "Owner $Id failed. $($state.failure) $($state.error)" }
    return $state
}
function Wait-Owners([scriptblock]$Check,[string]$Description) {
    $until=[DateTime]::UtcNow.AddSeconds(600)
    do {
        $server=Read-Owner 0
        $hub=Read-Owner 4
        if ($server -and $hub -and (& $Check $server $hub)) { return @($server,$hub) }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $until)
    throw "Production owner check timed out. $Description"
}
Stop-ArServer
foreach ($id in @(0,4)) {
    $disk="$TestRoot\world\computercraft\computer\$id"
    Copy-Item "$PSScriptRoot\ar-owner-probe.lua" $disk
    [IO.File]::WriteAllText("$disk\startup.lua",'shell.run("ar-owner-probe.lua")',$utf8)
}
Start-ArServer 'production-owner'
Rcon 'computercraft turn-on 0 1 2 3 4' | Out-Null
$first=Wait-Owners { param($s,$h) $s.programRunning -and $h.programRunning -and $s.attached -and $h.attached -and $s.updates -gt 0 -and $s.elementCount -gt 10 } 'both production programs started'
Start-Sleep -Seconds 40
$settled=Wait-Owners { param($s,$h) @($h.journal | Where-Object { $_.kind -eq 'lease' -and $_.direction -eq 'received' -and $_.arOwner -eq $true }).Count -gt 0 } 'hub received server ownership lease'
$hubMutations=$settled[1].mutations
Start-Sleep -Seconds 6
$sampleAfter=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$stable=Wait-Owners { param($s,$h) $s.time -ge $sampleAfter -and $h.time -ge $sampleAfter } 'fresh owner samples after suppression check'
$hub=$stable[1]
if ($hub.mutations -ne $hubMutations) { throw 'Hub mutated the shared controller during server ownership.' }
$injectionId=[guid]::NewGuid().ToString('N')
$injection=@{id=$injectionId;fault='stale-namespace'} | ConvertTo-Json -Compress
$injectionPath="$TestRoot\world\computercraft\computer\0\ar-owner-request.json"
[IO.File]::WriteAllText($injectionPath,$injection,$utf8)
$seeded=Wait-Owners { param($s,$h) $s.request -eq $injectionId -and
    $s.elementIds -contains 'ssot-ar:ore:test-stale' -and $s.elementIds -contains 'pr6-owner:foreign' -and
    $h.elementIds -contains 'ssot-ar:ore:test-stale' -and $h.elementIds -contains 'pr6-owner:foreign'
} 'explicit stale namespace fault reached the real shared controller'
$seeded[0] | ConvertTo-Json -Depth 30 | Set-Content "$Output\owner-fault-injection.json"
$seeded[1] | ConvertTo-Json -Depth 30 | Set-Content "$Output\owner-hub-before-takeover.json"
$oldHubUpdates=$hub.updates
$off=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Rcon 'computercraft shutdown 0' | Out-Null
$takeover=Wait-Owners { param($s,$h) $h.updates -gt $oldHubUpdates -and $h.lastUpdate -gt $off } 'hub took over after server shutdown'
if ($takeover[1].elementIds -contains 'ssot-ar:ore:test-stale') {
    throw 'Hub takeover left the explicitly injected stale SSOT ore edge on the shared controller.'
}
if ($takeover[1].elementIds -notcontains 'pr6-owner:foreign') {
    throw 'Hub takeover deleted the foreign namespace edge.'
}
$takeover[1] | ConvertTo-Json -Depth 30 | Set-Content "$Output\owner-hub-takeover.json"
$oldBoot=$settled[0].boot
Rcon 'computercraft turn-on 0' | Out-Null
$reclaimed=Wait-Owners { param($s,$h) $s.boot -gt $oldBoot -and $s.updates -gt 0 -and $s.lastUpdate -gt $off } 'server reclaimed after computer restart'
Start-Sleep -Seconds 35
$requestId=[guid]::NewGuid().ToString('N')
$sampleAfter=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$baseline=Wait-Owners { param($s,$h) $s.time -ge $sampleAfter -and $h.time -ge $sampleAfter } 'fresh owner samples before forwarded key'
$hub=$baseline[1]
$hubMutations=$hub.mutations
$server=$baseline[0]
$serverUpdates=$server.updates
@{requestId=$requestId;server=$server;hub=$hub} | ConvertTo-Json -Depth 30 |
    Set-Content "$Output\owner-key-baseline.json"
$request=@{id=$requestId;key='p'} | ConvertTo-Json -Compress
[IO.File]::WriteAllText("$TestRoot\world\computercraft\computer\4\ar-owner-request.json",$request,$utf8)
$toggled=Wait-Owners { param($s,$h) $h.request -eq $requestId -and $s.updates -gt $serverUpdates } 'hub key reached server-owned HUD'
Start-Sleep -Seconds 6
$sampleAfter=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$afterKey=Wait-Owners { param($s,$h) $h.request -eq $requestId -and $s.time -ge $sampleAfter -and
    $h.time -ge $sampleAfter } 'fresh owner samples after forwarded key'
$hub=$afterKey[1]
@{requestId=$requestId;server=$afterKey[0];hub=$hub} | ConvertTo-Json -Depth 30 |
    Set-Content "$Output\owner-key-after.json"
if ($hub.mutations -ne $hubMutations) { throw 'Hub drew while forwarding a layer key to the server.' }
Rcon 'setblock 1 66 0 minecraft:air' | Out-Null
$detached=Wait-Owners { param($s,$h) !$s.attached -and !$h.attached } 'both owners observed physical detach'
$serverUpdates=$detached[0].updates
Rcon 'setblock 1 66 0 cc_ar:ar_controller' | Out-Null
$restored=Wait-Owners { param($s,$h) $s.attached -and $h.attached -and $s.updates -gt $serverUpdates -and $s.elementCount -gt 5 } 'replacement controller redrew'
$restored[0] | ConvertTo-Json -Depth 30 | Set-Content "$Output\owner-server-restored.json"
$restored[1] | ConvertTo-Json -Depth 30 | Set-Content "$Output\owner-hub-restored.json"
@{ok=$true;sharedNativeController=$true;serverDeath=$true;serverRestart=$true;forwardedKey=$true;detach=$true;reattach=$true;
    staleNamespaceCleanup=$true;foreignNamespacePreserved=$true;namespaceFixture='Explicit native drawLine3D fault injection before server shutdown'} |
    ConvertTo-Json | Set-Content "$Output\owner-result.json"
