function Invoke-GatebRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Call,
        [int]$BudgetSec = 1200,
        [string]$Log = ''
    )
    $last = $null
    foreach ($delay in @(0, 2, 2, 2)) {
        if ($delay -gt 0) {
            $line = "gatebd unreachable, waited ${delay}s before attempt"
            if ($Log) { Add-Content -LiteralPath $Log -Value $line }
            Start-Sleep -Seconds $delay
        }
        try { return (& $Call) } catch { $last = $_ }
    }
    throw $last
}
