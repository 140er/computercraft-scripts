$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\role-closure.ps1"
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$names = @(Get-GateBundleRoleNames $source)
$failed = New-Object System.Collections.Generic.List[string]
foreach ($role in $names) {
    $entryRel = Get-GateBundleEntry $source $role
    $entry = Join-Path $source ($entryRel.Replace('/','\'))
    try {
        $copied = @(Get-GateRoleFiles -Source $source -Entry @($entry) -ManifestRole $role)
        $have = @{}
        foreach ($row in $copied) { $have[$row.DiskName] = $true }
        $want = Get-GateBundleFiles $source $role
        $missing = @($want.Keys | Where-Object { -not $have.ContainsKey($_) } | Sort-Object)
        if ($missing.Count -gt 0) { throw "copied set left out $($missing -join ', ')" }
        Write-Output ("PASS {0} {1} files" -f $role, $want.Count)
    } catch {
        $failed.Add($role)
        Write-Output ("FAIL {0} {1}" -f $role, $_.Exception.Message)
    }
}
if ($failed.Count -gt 0) {
    Write-Output ("FAIL {0} of {1} roles" -f $failed.Count, $names.Count)
    exit 1
}
Write-Output ("PASS {0} roles" -f $names.Count)
exit 0
