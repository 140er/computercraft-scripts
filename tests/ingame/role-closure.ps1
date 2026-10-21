$script:GateRoleRom = @(
    'gps','wget','pastebin','edit','lua','clear','exit','reboot','shutdown','programs','help',
    'cd','ls','dir','copy','move','delete','mkdir','id','label','monitor','rednet','bg','fg',
    'shell','alias','apis','attach','detach','drive','eject','equip','unequip','peripherals',
    'set','unset','time','type','which','hello','motd','list','rename','repeat'
)

function Get-GateEntries([string]$Source, [string]$Scenario, [int]$Id) {
    $tests = Join-Path $Source 'tests'
    $ingame = Join-Path $tests 'ingame'
    if ($Id -eq 0) { return @(Join-Path $ingame 'server.lua') }
    if ($Scenario -eq 'warehouse' -and $Id -eq 21) { return @(Join-Path $ingame 'loader-guardian.lua') }
    if ($Scenario -eq 'mining' -and $Id -eq 6) { return @(Join-Path $Source 'hub.lua') }
    if ($Scenario -eq 'mining') { return @(Join-Path $tests 'mining-runtime.lua') }
    if ($Scenario -eq 'warehouse') { return @(Join-Path $tests 'warehouse-runtime.lua') }
    $entries = @(Join-Path $tests 'ssot-runtime.lua')
    if ($Scenario -eq 'nav' -and $Id -eq 3) { $entries += Join-Path $ingame 'nav-probe.lua' }
    return $entries
}

function Get-LuaCalls([string]$Text) {
    $literals = New-Object System.Collections.Generic.List[object]
    $dynamics = New-Object System.Collections.Generic.List[object]
    $n = $Text.Length
    $i = 0
    $line = 1
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($c -eq "`n") { $line++; $i++; continue }
        if ($c -eq '-' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '-') {
            if ($Text.Substring($i).StartsWith('--[[')) {
                $end = $Text.IndexOf(']]', $i + 4)
                if ($end -lt 0) { break }
                $line += ([regex]::Matches($Text.Substring($i, $end - $i), "`n")).Count
                $i = $end + 2
                continue
            }
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq "'" -or $c -eq '"') {
            $q = $c
            $i++
            while ($i -lt $n -and $Text[$i] -ne $q) {
                if ($Text[$i] -eq '\') { $i += 2; continue }
                if ($Text[$i] -eq "`n") { $line++ }
                $i++
            }
            $i++
            continue
        }
        if ($c -eq '[') {
            $rest = $Text.Substring($i)
            $m = [regex]::Match($rest, '^\[(=*)\[')
            if ($m.Success) {
                $close = ']' + $m.Groups[1].Value + ']'
                $end = $Text.IndexOf($close, $i + $m.Length)
                if ($end -lt 0) { break }
                $line += ([regex]::Matches($Text.Substring($i, $end - $i), "`n")).Count
                $i = $end + $close.Length
                continue
            }
        }
        $boundary = ($i -eq 0) -or ($Text[$i - 1] -notmatch '[A-Za-z0-9_]')
        $kind = $null
        foreach ($name in @('shell.run','dofile','loadfile','require')) {
            if ($boundary -and $Text.Substring($i).StartsWith($name)) {
                $after = $i + $name.Length
                if ($after -lt $n -and $Text[$after] -match '[A-Za-z0-9_]') { continue }
                $kind = $name
                $i = $after
                break
            }
        }
        if (-not $kind) { $i++; continue }
        while ($i -lt $n -and ($Text[$i] -eq ' ' -or $Text[$i] -eq "`t" -or $Text[$i] -eq "`r" -or $Text[$i] -eq "`n")) {
            if ($Text[$i] -eq "`n") { $line++ }
            $i++
        }
        if ($i -ge $n -or $Text[$i] -ne '(') { continue }
        $i++
        while ($i -lt $n -and ($Text[$i] -eq ' ' -or $Text[$i] -eq "`t" -or $Text[$i] -eq "`r" -or $Text[$i] -eq "`n")) {
            if ($Text[$i] -eq "`n") { $line++ }
            $i++
        }
        if ($i -lt $n -and ($Text[$i] -eq "'" -or $Text[$i] -eq '"')) {
            $q = $Text[$i]
            $i++
            $buf = New-Object System.Text.StringBuilder
            while ($i -lt $n -and $Text[$i] -ne $q) {
                [void]$buf.Append($Text[$i])
                $i++
            }
            $i++
            $literals.Add([pscustomobject]@{ Kind = $kind; Arg = $buf.ToString(); Line = $line })
            continue
        }
        $snippet = ''
        $k = $i
        while ($k -lt $n -and $Text[$k] -ne "`n" -and ($k - $i) -lt 60) { $snippet += $Text[$k]; $k++ }
        $dynamics.Add([pscustomobject]@{ Kind = $kind; Arg = $snippet.Trim(); Line = $line })
    }
    return @{ Literals = $literals; Dynamics = $dynamics }
}

function Get-GateManifestRole([string]$Source, [string[]]$Entry) {
    $sourceFull = [IO.Path]::GetFullPath($Source)
    foreach ($path in $Entry) {
        $full = [IO.Path]::GetFullPath($path)
        $rel = $full.Substring($sourceFull.Length).TrimStart('\','/').Replace('\','/')
        if ($rel -eq 'tests/ingame/server.lua') { return 'server' }
        if ($rel -eq 'hub.lua') { return 'hub' }
    }
    return $null
}

function Get-GateBundleText([string]$Source) {
    return [IO.File]::ReadAllText((Join-Path $Source 'bundle-manifest.lua'))
}

function Get-GateBundleRoleNames([string]$Source) {
    $text = Get-GateBundleText $Source
    $start = $text.IndexOf('["roles"]={')
    $end = $text.IndexOf('["schema"]=', $start + 1)
    if ($start -lt 0 -or $end -lt 0) { throw "bundle-manifest.lua has no roles table." }
    $slice = $text.Substring($start, $end - $start)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($hit in [regex]::Matches($slice, '(?m)^    \["([^"]+)"\]=\{')) {
        $names.Add($hit.Groups[1].Value)
    }
    if ($names.Count -eq 0) { throw "bundle-manifest.lua lists no roles." }
    return @($names)
}

function Get-GateBundleEntry([string]$Source, [string]$Role) {
    $text = Get-GateBundleText $Source
    $body = [regex]::Match($text, '\["' + [regex]::Escape($Role) + '"\]=\{[\s\S]*?\["entry"\]="([^"]+)"')
    if (-not $body.Success) { throw "bundle-manifest.lua has no entry for $Role." }
    return $body.Groups[1].Value
}

function Get-GateBundleFiles([string]$Source, [string]$Role) {
    $text = Get-GateBundleText $Source
    $set = @{}
    if ($Role -eq '*stubs') {
        foreach ($hit in [regex]::Matches($text, '\["(lib/stubs/[^"]+\.lua)"\]=')) {
            $set[$hit.Groups[1].Value] = $true
        }
        if ($set.Count -eq 0) { throw "bundle-manifest.lua lists no lib/stubs files." }
        return $set
    }
    $body = [regex]::Match($text, '\["' + [regex]::Escape($Role) + '"\]=\{[\s\S]*?\["files"\]=\{([\s\S]*?)\r?\n      \}')
    if (-not $body.Success) { throw "bundle-manifest.lua has no file list for $Role." }
    foreach ($hit in [regex]::Matches($body.Groups[1].Value, '="([^"]+)"')) {
        $set[$hit.Groups[1].Value] = $true
    }
    if ($set.Count -eq 0) { throw "bundle-manifest.lua lists no files for $Role." }
    return $set
}

function Test-GateDynamicAllowed([string]$RelHere, $Dyn) {
    $rel = $RelHere -replace '\\','/'
    if ($rel -eq 'wh2-program.lua' -and $Dyn.Kind -eq 'loadfile' -and $Dyn.Arg.StartsWith('path')) { return $true }
    if ($Dyn.Kind -eq 'shell.run' -and $Dyn.Arg.StartsWith('shell.getRunningProgram()')) { return $true }
    return $false
}

function Test-GateScannable([string]$Path, [string]$SourceFull) {
    $calls = Get-LuaCalls ([IO.File]::ReadAllText($Path))
    $relHere = $Path.Substring($SourceFull.Length).TrimStart('\','/').Replace('\','/')
    foreach ($dyn in $calls.Dynamics) {
        if (-not (Test-GateDynamicAllowed $relHere $dyn)) { return $false }
    }
    return $true
}

function Get-GateRoleFiles([string]$Source, [string[]]$Entry, [string]$ManifestRole) {
    $sourceFull = [IO.Path]::GetFullPath($Source)
    $allow = @(
        (Join-Path $sourceFull 'tests\ssot-runtime.lua'),
        (Join-Path $sourceFull 'tests\mining-runtime.lua'),
        (Join-Path $sourceFull 'tests\warehouse-runtime.lua'),
        (Join-Path $sourceFull 'tests\warehouse-fixture.lua'),
        (Join-Path $sourceFull 'tests\ingame\server.lua'),
        (Join-Path $sourceFull 'tests\ingame\nav-probe.lua'),
        (Join-Path $sourceFull 'tests\ingame\loader-guardian.lua'),
        (Join-Path $sourceFull 'tests\ingame\charge-probe.lua'),
        (Join-Path $sourceFull 'tests\gate-disk.lua')
    )
    $manifestRole = if ($ManifestRole) { $ManifestRole } else { Get-GateManifestRole $Source $Entry }
    $roleFiles = $null
    $stubAllow = @{}
    if ($manifestRole) {
        $roleFiles = Get-GateBundleFiles $Source $manifestRole
        foreach ($relStub in @($roleFiles.Keys)) {
            if ($relStub.StartsWith('lib/stubs/')) { $stubAllow[$relStub] = $true }
        }
    } else {
        $stubAllow = Get-GateBundleFiles $Source '*stubs'
    }
    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($path in $Entry) {
        $full = [IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $full)) { throw "Gate B entry is missing: $path" }
        $queue.Enqueue($full)
    }
    while ($true) {
    while ($queue.Count -gt 0) {
        $path = $queue.Dequeue()
        if ($seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        $calls = Get-LuaCalls ([IO.File]::ReadAllText($path))
        $relHere = $path.Substring($sourceFull.Length).TrimStart('\','/')
        foreach ($dyn in $calls.Dynamics) {
            if (-not (Test-GateDynamicAllowed $relHere $dyn)) { throw "Unresolved dynamic $($dyn.Kind) in ${relHere}:$($dyn.Line): $($dyn.Arg)" }
        }
        foreach ($lit in $calls.Literals) {
            $spec = $lit.Arg
            $bare = [IO.Path]::GetFileName($spec)
            if ($script:GateRoleRom -contains $spec -or $script:GateRoleRom -contains $bare -or $spec.StartsWith('cc.') -or $spec.StartsWith('cc/')) { continue }
            $rel = if ($spec.EndsWith('.lua')) { $spec } else { ($spec -replace '\.','/') + '.lua' }
            $rel = $rel -replace '/','\'
            $name = [IO.Path]::GetFileName($rel)
            $candidates = @(
                (Join-Path $sourceFull $rel),
                (Join-Path $sourceFull "tests\$name"),
                (Join-Path $sourceFull "tests\ingame\$name"),
                (Join-Path $sourceFull "tests\sandbox\$name")
            )
            $found = New-Object System.Collections.Generic.List[string]
            foreach ($candidate in $candidates) {
                if ((Test-Path -LiteralPath $candidate) -and -not $found.Contains([IO.Path]::GetFullPath($candidate))) {
                    $found.Add([IO.Path]::GetFullPath($candidate))
                }
            }
            if ($found.Count -eq 0) { throw "Unresolved $($lit.Kind)('$spec') in ${relHere}:$($lit.Line)" }
            $target = $null
            foreach ($item in $found) {
                if ([IO.Path]::GetDirectoryName($item) -eq $sourceFull) { $target = $item; break }
            }
            if (-not $target) { $target = $found[0] }
            $relTarget = $target.Substring($sourceFull.Length).TrimStart('\','/').Replace('\','/')
            if ($relTarget.StartsWith('lib/stubs/')) {
                if (-not $stubAllow.ContainsKey($relTarget)) { continue }
                if (-not $seen.ContainsKey($target)) { $queue.Enqueue($target) }
                continue
            }
            $underTests = $relTarget.StartsWith('tests/')
            $allowedTests = $allow -contains $target
            if ($underTests -and -not $allowedTests) { continue }
            $atRoot = [IO.Path]::GetDirectoryName($target) -eq $sourceFull
            if (-not $atRoot -and -not $allowedTests) { throw "Gate B cannot place $relTarget on a computer. $($lit.Kind)('$spec') in ${relHere}:$($lit.Line)" }
            if (-not $seen.ContainsKey($target)) { $queue.Enqueue($target) }
        }
    }
        if (-not $roleFiles) { break }
        $progress = $false
        foreach ($rel in @($roleFiles.Keys)) {
            if ($rel.StartsWith('lib/stubs/')) { continue }
            $src = [IO.Path]::GetFullPath((Join-Path $sourceFull ($rel.Replace('/','\'))))
            if (-not (Test-Path -LiteralPath $src) -or $seen.ContainsKey($src)) { continue }
            if (Test-GateScannable $src $sourceFull) { $queue.Enqueue($src) } else { $seen[$src] = $true }
            $progress = $true
        }
        if (-not $progress) { break }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($path in $seen.Keys) {
        $rel = $path.Substring($sourceFull.Length).TrimStart('\','/').Replace('\','/')
        $disk = if ($path -eq [IO.Path]::GetFullPath((Join-Path $sourceFull 'tests\ingame\server.lua'))) { 'test-server.lua' }
            elseif ($rel.StartsWith('lib/stubs/')) { $rel }
            else { [IO.Path]::GetFileName($path) }
        $rows.Add([pscustomobject]@{ DiskName = $disk; SourcePath = $path })
    }
    if ($roleFiles) {
        $have = @{}
        foreach ($row in $rows) { $have[$row.DiskName] = $true }
        $missing = @($roleFiles.Keys | Where-Object { -not $have.ContainsKey($_) } | Sort-Object)
        if ($missing.Count -gt 0) {
            throw "Gate B copy left out files bundle-manifest.lua lists for ${manifestRole}: $($missing -join ', ')"
        }
    }
    $names = @{}
    foreach ($row in $rows) {
        if ($names.ContainsKey($row.DiskName)) { throw "Two gate B files want the disk name $($row.DiskName)." }
        $names[$row.DiskName] = $true
    }
    return @($rows | Sort-Object DiskName)
}

function Write-GateRoleFiles([string]$Disk, [string]$Source, [string[]]$Entry, [Text.Encoding]$Utf8) {
    $files = @(Get-GateRoleFiles -Source $Source -Entry $Entry)
    foreach ($file in $files) {
        $dest = [IO.Path]::Combine($Disk, ($file.DiskName -replace '/','\'))
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
        $text = [IO.File]::ReadAllText($file.SourcePath).Replace("`r`n","`n")
        [IO.File]::WriteAllText($dest, $text, $Utf8)
    }
    return $files
}

if ($MyInvocation.InvocationName -ne '.') {
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $utf8 = New-Object Text.UTF8Encoding($false)
    $roles = @(
        @{ Name = 'server'; Scenario = 'ssot'; Id = 0 },
        @{ Name = 'ssot'; Scenario = 'ssot'; Id = 1 },
        @{ Name = 'nav'; Scenario = 'nav'; Id = 3 },
        @{ Name = 'mining'; Scenario = 'mining'; Id = 1 },
        @{ Name = 'hub'; Scenario = 'mining'; Id = 6 },
        @{ Name = 'warehouse'; Scenario = 'warehouse'; Id = 1 },
        @{ Name = 'loader'; Scenario = 'warehouse'; Id = 21 }
    )
    foreach ($role in $roles) {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("gate-role-" + $role.Name)
        if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        New-Item -ItemType Directory -Path $root | Out-Null
        $entries = Get-GateEntries $source $role.Scenario $role.Id
        Write-GateRoleFiles -Disk $root -Source $source -Entry $entries -Utf8 $utf8 | Out-Null
        $sum = 0
        Get-ChildItem $root -Recurse -File | Sort-Object FullName | ForEach-Object {
            $sum += $_.Length
            $rel = $_.FullName.Substring($root.Length).TrimStart('\')
            Write-Output ("{0,8}  {1}" -f $_.Length, $rel)
        }
        Write-Output ("== {0} == {1} files {2} bytes" -f $role.Name, (Get-ChildItem $root -Recurse -File).Count, $sum)
    }
}
