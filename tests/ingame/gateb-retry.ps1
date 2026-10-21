Add-Type -AssemblyName System.Net.Http

function Get-GatebHealthAttempt {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Gateb-Token', [string]$script:GatebToken)
        $resp = $client.GetAsync("$($script:GatebUrl)/health").GetAwaiter().GetResult()
        try {
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) { throw "gateb GET /health -> $([int]$resp.StatusCode) $text" }
            return ($text | ConvertFrom-Json)
        } finally { $resp.Dispose() }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-GatebRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Call,
        [int]$BudgetSec = 1200,
        [string]$Log = ''
    )
    $started = [DateTime]::UtcNow
    $delay = 0
    $attempt = 1
    while ($true) {
        if ($delay -gt 0) {
            $line = "gatebd unreachable, waited ${delay}s before attempt $attempt"
            if ($Log) { Add-Content -LiteralPath $Log -Value $line }
            if (Get-Command Set-Phase -ErrorAction SilentlyContinue) { Set-Phase $line }
            Start-Sleep -Seconds $delay
        }
        try {
            return (& $Call)
        } catch {
            $last = $_
            $spent = ([DateTime]::UtcNow - $started).TotalSeconds
            if ($spent -ge $BudgetSec) { throw $last }
            $delay = if ($delay -lt 1) { 1 } else { [Math]::Min(60, [int]$delay * 2) }
            $remain = [int][Math]::Floor($BudgetSec - $spent)
            if ($remain -lt 1) { throw $last }
            if ($delay -gt $remain) { $delay = $remain }
            $attempt++
        }
    }
}

function Invoke-GatebBoundCall {
    $bound = $script:GatebBound
    if ($bound.Method -eq 'GET' -and $bound.Path -eq '/health') { return Get-GatebHealthAttempt }
    & $bound.Raw $bound.Method $bound.Path $bound.Body $bound.OutFile -Raw:$bound.RawBytes -AllowMissing:$bound.AllowMissing
}

function Invoke-GatebWrapped {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [string]$OutFile = $null,
        [switch]$Raw,
        [switch]$AllowMissing
    )
    $script:GatebBound = @{
        Method = $Method
        Path = $Path
        Body = $Body
        OutFile = $OutFile
        RawBytes = [bool]$Raw
        AllowMissing = [bool]$AllowMissing
        Raw = $script:GatebInvokeRaw
    }
    Invoke-GatebRetry -Log $script:GatebRetryLog -Call { Invoke-GatebBoundCall }
}

function Install-GatebRetry([string]$Log) {
    $script:GatebInvokeRaw = (Get-Command Invoke-Gateb -CommandType Function).ScriptBlock
    $script:GatebRetryLog = $Log
    Set-Item -Path function:script:Invoke-Gateb -Value ${function:Invoke-GatebWrapped}
}
