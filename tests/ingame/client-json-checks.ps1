$ErrorActionPreference='Stop'
$tokens=$null
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\client.ps1",[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$reader=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-ClientJson'},$true)
if (!$reader) { throw 'Client JSON reader missing.' }
. ([scriptblock]::Create($reader.Extent.Text))
$path=Join-Path $env:TEMP ("pr5-client-json-"+[guid]::NewGuid().ToString('N')+".json")
try {
    if ($null -ne (Read-ClientJson $path)) { throw 'Missing file was ready.' }
    foreach ($partial in @('', ' ', '{"ok":', '{"ok":true,')) {
        [IO.File]::WriteAllText($path,$partial)
        if ($null -ne (Read-ClientJson $path)) { throw 'Partial JSON was ready.' }
    }
    $text='{"ok":true,"frameCount":12}'
    [IO.File]::WriteAllText($path,$text)
    $ready=Read-ClientJson $path
    if ($ready.Value.ok -isnot [bool] -or !$ready.Value.ok) { throw 'Completed pass was not readable.' }
    [IO.File]::WriteAllText($path,'{"ok":false,"error":"probe failed"}')
    $failed=Read-ClientJson $path
    if ($failed.Value.ok -isnot [bool] -or $failed.Value.ok) { throw 'Completed failure was not readable.' }
    if ([Text.Encoding]::UTF8.GetString($ready.Bytes) -ne $text) { throw 'Evidence bytes changed after parsing.' }
    'PASS client JSON waits tolerate incomplete writes and retain completed failure verdicts.'
    'PASS client evidence retains the exact parsed bytes.'
    'PASS client.ps1 syntax.'
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}
