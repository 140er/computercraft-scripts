$ErrorActionPreference = 'Stop'
$client = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ingame/client.ps1') -Raw
$pattern = '[$!]confirm\s+([A-Za-z0-9-]+)'
$copies = [regex]::Matches($client, [regex]::Escape($pattern)).Count
if ($copies -lt 5) { throw "Client confirmation parser drifted. Copies=$copies." }
if ($client -match "-notmatch 'confirm\\s\+") { throw 'Client parser can capture the action word.' }
$samples = @(
    @{ text = 'Confirm pro within 30s with $confirm 1792507079916-1035969124-1'; token = '1792507079916-1035969124-1' },
    @{ text = 'Confirm hub within 30s with !confirm 99-1'; token = '99-1' }
)
foreach ($sample in $samples) {
    if ($sample.text -notmatch $pattern) { throw "No token in $($sample.text)" }
    if ($Matches[1] -eq 'pro' -or $Matches[1] -ne $sample.token) { throw "Captured $($Matches[1]) from $($sample.text)" }
}
foreach ($command in @('!pro', '$pro', 'Confirm pro within 30s')) {
    if ($command -match $pattern) { throw "$command looked like a confirmation token." }
}
Write-Output 'PASS confirmation token parser'
