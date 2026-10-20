function Set-ArChargeStation([string]$Mode) {
    Rcon 'setblock 24 65 -8 minecraft:air' | Out-Null
    if ($Mode -ne 'missing') {
        Rcon 'setblock 24 65 -8 superbwarfare:charging_station' | Out-Null
        $item = if ($Mode -eq 'powered') { 'minecraft:coal_block 64' } else { 'minecraft:air' }
        Rcon "item replace block 24 65 -8 container.0 with $item" | Out-Null
        if ($Mode -ne 'powered') { Rcon 'data merge block 24 65 -8 {Energy:0}' | Out-Null }
    }
}
function Initialize-ArRecharge {
    Rcon 'fill 16 64 -8 31 64 6 minecraft:stone' | Out-Null
    Rcon 'fill 16 65 -8 31 68 6 minecraft:air' | Out-Null
    Set-ArChargeStation 'missing'
    foreach ($id in $depthIds) {
        $x=$depthHomes[$id]
        Rcon "setblock $x 65 5 minecraft:chest" | Out-Null
        $arDepthServices[$id]="{enabled=true,drop='ar-drop-$id',charger='ar-charge-$id',targetFuel=10000,chargeTimeout=60000}"
        $arDepthSurveys[$id]=@(
            @{x=$x+1;y=65;z=8},@{x=$x+1;y=65;z=0},@{x=$x;y=65;z=0},
            @{x=$x+1;y=65;z=0},@{x=$x+1;y=65;z=6},@{x=$x;y=65;z=6},
            @{x=$x+1;y=65;z=6},@{x=$x+1;y=65;z=8},@{x=$x;y=65;z=8})
    }
}
function Register-ArRecharge {
    foreach ($id in $depthIds) {
        foreach ($kind in @('drop','charge')) {
            $z=if ($kind -eq 'drop') {6} else {0}
            $rid=Send-DepthRequest 20 @{action='service-site';name="ar-$kind-$id";site=@{
                kind=$kind;pose=@{dim='minecraft:overworld';x=$depthHomes[$id];y=65;z=$z;h=0};side='front'}}
            Wait-DepthRequest 20 $rid | Out-Null
        }
    }
}
function Test-ArHome($Row,[int]$Id) {
    return $Row.pose -and $Row.pose.x -eq $depthHomes[$Id] -and $Row.pose.y -eq 65 -and $Row.pose.z -eq 8
}
function Save-ArRecharge([string]$Label) {
    Save-Depth "recharge-$Label"
    foreach ($id in $depthIds) {
        Save-ArFile "$TestRoot\world\computercraft\computer\$id\mining-warehouse.state" "$Output\recharge-$Label-$id-service.state"
    }
    Rcon 'data get block 24 65 -8' | Set-Content "$Output\recharge-$Label-station.txt"
}
function Invoke-ArTravelChat([string]$Action) {
    if (!(Get-Command Invoke-ArCapture -ErrorAction SilentlyContinue)) { throw 'Real AP chat capture is required for recall and recharge.' }
    $server=Read-Depth 0
    $script:arChatAction=$Action
    $script:arChatAfter=$server.time
    $script:arChatReplyCount=@($server.replies).Count
    $before=$server.time
    $view=if ($Action -eq 'hub') {'ar-recall'} else {'ar-recharge'}
    Invoke-ArCapture $view
    $s=Wait-Depth {param($rows)
        $chat=@($rows[0].chat | Where-Object {$_.at -gt $before -and $_.name -eq $arTestOwnerName})
        $replies=@($rows[0].replies | Where-Object {$_.at -gt $before -and $_.name -eq $arTestOwnerName})
        return @($chat | Where-Object {$_.message -eq "!$Action"}).Count -gt 0 -and
            @($chat | Where-Object {$_.message -like '!confirm *'}).Count -gt 0 -and
            @($replies | Where-Object {$_.text -match 'queued'}).Count -gt 0
    } "fresh real AP !$Action request, confirmation and queued reply" 90
    return @{after=$before;chat=@($s[0].chat | Where-Object {$_.at -gt $before});
        replies=@($s[0].replies | Where-Object {$_.at -gt $before})}
}
function Wait-ArChargeCompletion($Before,[int[]]$Ids,[string]$Outcome) {
    return Wait-Depth {param($s)
        foreach ($id in $Ids) {
            $row=$s[$id]
            if (!$row.control -or $row.control.kind -ne 'recharge' -or !$row.control.complete -or
                ($row.control.epoch -eq $Before[$id].control.epoch -and $row.control.cid -le $Before[$id].control.cid) -or
                $row.status.rechargeResult -ne $Outcome -or !(Test-ArHome $row $id)) { return $false }
        }
        return $true
    } "recharge $Outcome completed and returned home" 180
}
function Get-ArChargeEvidence($Before,$After,[int[]]$Ids,[bool]$RequireRise) {
    $rows=@()
    foreach ($id in $Ids) {
        $delta=$After[$id].fuel-$Before[$id].fuel
        if ($RequireRise -and $delta -le 0) { throw "Turtle $id reported charging without a measured fuel increase." }
        if (!$RequireRise -and $delta -gt 0) { throw "Turtle $id gained fuel while the charger was unavailable." }
        $block=Rcon "data get block $($depthHomes[$id]) 65 8"
        if ($block -notmatch "ComputerId:\s*$id(?=[,}\s])") { throw "Turtle $id is absent at its reported home." }
        $rows+=@{id=$id;fuelBefore=$Before[$id].fuel;fuelAfter=$After[$id].fuel;fuelDelta=$delta;
            controlBefore=$Before[$id].control;controlAfter=$After[$id].control;pose=$After[$id].pose;
            result=$After[$id].status.rechargeResult;physicalBlock=$block}
    }
    return $rows
}
function Invoke-ArRechargeChecks {
    $firstCheck=$depthChecks.Count
    Check-Depth 'real AP confirmed recall returns four production miners home' {
        $before=@{}; foreach($id in $depthIds){$before[$id]=Read-Depth $id}
        $chat=Invoke-ArTravelChat 'hub'
        $atHome=Wait-Depth {param($s)
            foreach ($id in $depthIds) {
                if ($s[$id].control.kind -ne 'recall' -or !(Test-ArHome $s[$id] $id) -or
                    ($s[$id].control.epoch -eq $before[$id].control.epoch -and
                        $s[$id].control.cid -le $before[$id].control.cid)) {return $false}
            }
            return $true
        } 'all four production miners recalled home' 300
        foreach ($id in $depthIds) {
            $block=Rcon "data get block $($depthHomes[$id]) 65 8"
            if ($block -notmatch "ComputerId:\s*$id(?=[,}\s])") {throw "Recalled turtle $id is absent at its reported home."}
        }
        Save-ArRecharge 'recalled'
        @{chat=$chat;miners=@(foreach($id in $depthIds){@{id=$id;pose=$atHome[$id].pose;control=$atHome[$id].control}})}
    }
    Check-Depth 'recalled production miners load the charging proof target after restart' {
        $before=Wait-Depth {param($s)
            foreach ($id in $depthIds) {
                if ($s[$id].control.kind -ne 'recall' -or !(Test-ArHome $s[$id] $id)) {return $false}
            }
            return $true
        } 'all miners stopped at home before service configuration changes'
        Rcon ("computercraft shutdown "+($depthIds -join ' ')) | Out-Null
        foreach ($id in $depthIds) {
            $path="$TestRoot\world\computercraft\computer\$id\miner.cfg"
            $text=Read-ArText $path
            if ([regex]::Matches($text,'targetFuel=10000').Count -ne 1) {
                throw "Turtle $id did not retain the expected initial service configuration."
            }
            Write-ArText $path ($text.Replace('targetFuel=10000','targetFuel=40000'))
        }
        Rcon ("computercraft turn-on "+($depthIds -join ' ')) | Out-Null
        $after=Wait-Depth {param($s)
            foreach ($id in $depthIds) {
                if ($s[$id].boot -le $before[$id].boot -or $s[$id].serviceTarget -ne 40000 -or
                    $s[$id].control.kind -ne 'recall' -or !(Test-ArHome $s[$id] $id) -or
                    !$s[$id].status.rechargeAvailable) {return $false}
            }
            return $true
        } 'restarted miners retained recall and loaded the actual service target' 180
        Save-ArRecharge 'configured'
        @(foreach($id in $depthIds){@{id=$id;beforeBoot=$before[$id].boot;afterBoot=$after[$id].boot;
            target=$after[$id].serviceTarget;control=$after[$id].control;pose=$after[$id].pose}})
    }
    Check-Depth 'real AP confirmed recharge raises fuel and returns four production miners home' {
        $before=@{}; foreach($id in $depthIds){$before[$id]=Read-Depth $id}
        Set-ArChargeStation 'powered'
        $chat=Invoke-ArTravelChat 'recharge'
        $after=Wait-ArChargeCompletion $before $depthIds 'charged'
        $miners=Get-ArChargeEvidence $before $after $depthIds $true
        Save-ArRecharge 'charged'
        @{chat=$chat;miners=$miners}
    }
    foreach ($mode in @('missing','unpowered')) {
        Check-Depth "$mode native charger reports no fuel rise and returns home" {
            Set-ArChargeStation $mode
            $before=@{1=(Read-Depth 1)}
            DepthCommand 'recharge' 1 | Out-Null
            $after=Wait-ArChargeCompletion $before @(1) 'no charging fuel rise'
            $miners=Get-ArChargeEvidence $before $after @(1) $false
            Save-ArRecharge $mode
            @{station=$mode;miners=$miners}
        }
    }
    Check-Depth 'power loss during native recharge resumes the saved request and returns home' {
        Set-ArChargeStation 'unpowered'
        $before=@{1=(Read-Depth 1)}
        DepthCommand 'recharge' 1 | Out-Null
        $charging=Wait-Depth {param($s)
            return $s[1].control.kind -eq 'recharge' -and !$s[1].control.complete -and
                $s[1].service.phase -eq 'charge' -and $s[1].service.charge.deadline -and
                $s[1].pose.x -eq $depthHomes[1] -and $s[1].pose.z -eq 0
        } 'production turtle reached the unpowered charging bay' 120
        Rcon 'computercraft shutdown 1' | Out-Null
        $charging[1] | ConvertTo-Json -Depth 30 | Set-Content "$Output\recharge-power-cut.json"
        Set-ArChargeStation 'powered'
        Rcon 'computercraft turn-on 1' | Out-Null
        $after=Wait-ArChargeCompletion $before @(1) 'charged'
        if ($after[1].boot -le $charging[1].boot) {throw 'Charging evidence did not include a native computer restart.'}
        $miners=Get-ArChargeEvidence $before $after @(1) $true
        Save-ArRecharge 'power-restored'
        @{beforeBoot=$charging[1].boot;afterBoot=$after[1].boot;pending=$charging[1].control;miners=$miners}
    }
    $checks=@($depthChecks | Select-Object -Skip $firstCheck)
    $checks | ConvertTo-Json -Depth 30 | Set-Content "$Output\recharge-result.json"
    if (@($checks | Where-Object {!$_.ok}).Count) {throw 'Native recharge checks failed. See recharge-result.json.'}
    return @{checks=$checks}
}
