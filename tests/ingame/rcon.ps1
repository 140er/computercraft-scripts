function Invoke-TestRcon {
    param([int]$Port, [string]$Password, [string]$Command)
    $python = 'C:\Tools\python\cpython-3.12.15-windows-x86_64-none\python.exe'
    $request = @{ port = $Port; password = $Password; command = $Command } | ConvertTo-Json -Compress
    $response = $request | & $python "$PSScriptRoot\rcon.py" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($response -join "`n") }
    $response -join "`n"
}
