# Gate B fixture wrapper. Dot-source this file, then call Invoke-GateBFixture.
# The caller passes the host, the port and the password.

function Invoke-GateBFixture {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Operation,
        [hashtable]$Args,
        [string]$Log = "rcon.txt",
        [string]$Python = ""
    )
    if (-not $Python) {
        $python3 = Get-Command python3 -ErrorAction SilentlyContinue
        $python = Get-Command python -ErrorAction SilentlyContinue
        if ($python3) { $Python = $python3.Source }
        elseif ($python) { $Python = $python.Source }
        else { throw "python3 is required" }
    }
    $payload = @{
        host = $HostName
        port = $Port
        password = $Password
        log = $Log
        op = $Operation
        args = $Args
    }
    $json = $payload | ConvertTo-Json -Depth 30 -Compress
    $response = $json | & $Python "$PSScriptRoot\cli.py"
    if ($LASTEXITCODE -ne 0) { throw ($response -join "`n") }
    $response -join "`n"
}

function Request-FixtureRestart {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][scriptblock]$Callback,
        [string]$Reason = "",
        [string]$Log = "rcon.txt"
    )
    Invoke-GateBFixture -HostName $HostName -Port $Port -Password $Password -Operation prepare_restart -Args @{ reason = $Reason } -Log $Log | Out-Null
    & $Callback
}
