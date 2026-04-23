function Generate-Report {
    param(
        [hashtable]$State,
        [string]$PathValue,
        [pscustomobject]$Config
    )

    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $rows = @()

    # Processed
    foreach ($key in $State.processed.Keys) {
        $proc = $State.processed[$key]
        $caseName = ($key -split '\|')[1]
        $status = 'Processed'
        $pct = 100
        $dtIni = $proc.ContainsKey('StartedAt') ? $proc.StartedAt : ''
        $dtEnd = $proc.ContainsKey('ProcessedAt') ? $proc.ProcessedAt : ''
        $rows += "<tr><td>$caseName</td><td>$status</td><td>$pct%</td><td>$dtIni</td><td>$dtEnd</td></tr>"
    }

    # Processing
    foreach ($key in $State.pending.Keys) {
        $pend = $State.pending[$key]
        $caseName = ($key -split '\|')[1]
        $status = 'Processing'
        $dtIni = $pend.ContainsKey('StartedAt') ? $pend.StartedAt : ''
        $dtEnd = ''
        # Try to get % from log
        $paths = Get-IPEDPaths -Series ([pscustomobject]@{ CaseName = $caseName }) -Config $Config
        $pct = Get-IPEDProgressPercentFromLog -LogPath $paths.LogPath
        if ($null -eq $pct) { $pct = 0 }
        $rows += "<tr><td>$caseName</td><td>$status</td><td>$pct%</td><td>$dtIni</td><td>$dtEnd</td></tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <title>IPEDflow Status</title>
    <style>
        body { font-family: Arial, sans-serif; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
        th { background: #eee; }
        tr:nth-child(even) { background: #f9f9f9; }
    </style>
</head>
<body>
    <h2>IPEDflow Status</h2>
    <p>Last update: $now</p>
    <table>
        <tr><th>Material</th><th>Status</th><th>%</th><th>Start</th><th>End</th></tr>
        $($rows -join "`n")
    </table>
</body>
</html>
"@
    Set-Content -LiteralPath $PathValue -Value $html -Encoding UTF8
}
