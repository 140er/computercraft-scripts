$installRoot=[IO.Path]::GetFullPath($TestRoot)
if ($installRoot -notmatch '^C:\\Work\\mc-ssot-pr6-[a-zA-Z0-9-]+$') { throw 'Installer phase requires the owned PR 6 test root.' }
if (!(Test-ArServer)) { throw 'Installer phase requires the owned test server to be running.' }
$installFailures=@()
$installRows=@()
function Invoke-NativeInstall([int]$Id,[string]$Role='') {
    $disk=Join-Path $TestRoot "world\computercraft\computer\$Id"
    $resultPath=Join-Path $disk 'data\ar-install-result.json'
    if ($null -ne (Read-ArText $resultPath)) { throw 'Installer result already exists. Use a fresh test root.' }
    Rcon "computercraft shutdown $Id" | Out-Null
    Copy-ArFile "$source\install.lua" "$disk\install.lua"
    Copy-ArFile "$source\update.lua" "$disk\update.lua"
    Copy-ArFile "$source\bundle-manifest.lua" "$disk\bundle-manifest.lua"
    Copy-ArFile "$arDriverRoot\fixtures\update-v1.lua" "$disk\data\update-v1.lua"
    Copy-ArFile "$PSScriptRoot\ar-install-probe.lua" "$disk\ar-install-probe.lua"
    $startup=if ($Role) { "shell.run('ar-install-probe.lua','$Role')" } else { "shell.run('ar-install-probe.lua')" }
    Write-ArText "$disk\startup.lua" $startup
    Rcon "computercraft turn-on $Id" | Out-Null
    $until=[DateTime]::UtcNow.AddSeconds([Math]::Max($Timeout,1800))
    do {
        if (!(Test-ArServer)) { throw 'Owned server exited during native installer checks.' }
        $value=$null
        try { $value=Read-ArText $resultPath | ConvertFrom-Json } catch {}
        if ($value -and ($value.ok -or $value.error)) {
            Save-ArFile $resultPath "$Output\native-install-$Id.json"
            foreach ($row in $value.roles) {
                $row.after | Set-Content "$Output\native-ls-$Id-$($row.role).txt"
            }
            return $value
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $until)
    throw "Native installer probe $Id timed out."
}
try {
    $value=Invoke-NativeInstall 4
    $installRows+=@{computer=4;role='all';result=$value}
    $pending=@('pro','view-map','view-pro','view-warehouse','vworld') | Sort-Object
    $got=@($value.unavailable | ForEach-Object { $_.role }) | Sort-Object
    if (($pending -join ',') -ne ($got -join ',')) {
        $installFailures += "Unavailable roles were $($got -join ', ')."
    }
    if (!$value.ok) { $installFailures+=$value.error }
} catch { $installFailures+=$_.Exception.Message }
finally { Rcon 'computercraft shutdown 4' | Out-Null }

try {
    Rcon 'computercraft shutdown 0 1 2 3 7' | Out-Null
    $serverCfg=Read-ArText "$TestRoot\world\computercraft\computer\0\ssot.cfg"
    if (!$serverCfg.Contains('controllers={')) { throw 'The production depth controller configuration is missing.' }
    $serverCfg=$serverCfg.Replace('controllers={',"controllers={['5']='pr6-install-miner-5-secret',['6']='pr6-install-store-6-secret',")
    Write-ArText "$TestRoot\world\computercraft\computer\0\ssot.cfg" $serverCfg
    Rcon 'computercraft turn-on 0 10 11 12 13' | Out-Null
    foreach ($command in @('forceload add -16 0 0 31','fill -12 64 12 -3 64 22 minecraft:stone',
        'fill -12 65 12 -3 68 22 minecraft:air',
        'setblock -10 65 16 computercraft:turtle_advanced[facing=south]{ComputerId:5,Fuel:10000,LeftUpgrade:"computercraft:wireless_modem_advanced",RightUpgrade:"minecraft:diamond_pickaxe"}',
        'setblock -6 65 16 computercraft:turtle_advanced[facing=south]{ComputerId:6,Fuel:10000,LeftUpgrade:"computercraft:wireless_modem_advanced"}')) {
        Rcon $command | Out-Null
    }
    Write-ArText "$TestRoot\world\computercraft\computer\5\miner.cfg" "{home={x=-10,y=65,z=16},facing=2,spine=2,ssot={enabled=true,server=0,secret='pr6-install-miner-5-secret',dimension='minecraft:overworld',timeout=5},nav={enabled=true,bounds={min={dim='minecraft:overworld',x=-12,y=64,z=12},max={dim='minecraft:overworld',x=-3,y=68,z=22}}},mining={enabled=true,home={dim='minecraft:overworld',x=-10,y=65,z=16,h=2}}}"
    Write-ArText "$TestRoot\world\computercraft\computer\6\warehouse.cfg" "{enabled=true,server=0,secret='pr6-install-store-6-secret',dimension='minecraft:overworld',pose={dim='minecraft:overworld',x=-6,y=65,z=16,h=2},bounds={min={dim='minecraft:overworld',x=-12,y=64,z=12},max={dim='minecraft:overworld',x=-3,y=68,z=22}}}"
    foreach ($entry in @(@{id=5;role='miner'},@{id=6;role='store'})) {
        try {
            $value=Invoke-NativeInstall $entry.id $entry.role
            $installRows+=@{computer=$entry.id;role=$entry.role;result=$value}
            if (!$value.ok) { $installFailures+=$value.error }
        } catch { $installFailures+=$_.Exception.Message }
        finally { Rcon "computercraft shutdown $($entry.id)" | Out-Null }
    }
} catch { $installFailures+=$_.Exception.Message }
@{ok=$installFailures.Count -eq 0;computers=$installRows;errors=$installFailures} |
    ConvertTo-Json -Depth 40 | Set-Content "$Output\native-install-result.json"
if ($installFailures.Count) { throw ($installFailures -join '; ') }
