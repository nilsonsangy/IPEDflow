[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$IpedProfile,
    [switch]$RunOnce
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) "ipedflow.conf"
}

function Resolve-ConfigPath {
    param([string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path (Split-Path -Parent $PSScriptRoot) $PathValue
}

function Ensure-ParentDirectory {
    param([string]$PathValue)

    $parent = Split-Path -Parent $PathValue
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

function Ensure-Directory {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -Path $PathValue -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Add-Content -LiteralPath $script:LogFile -Value $line
    Write-Host $line
}

function Load-Config {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        throw "Config file not found: $PathValue"
    }

    $rawConfig = @{}
    $rawConfig["MONITOR_ROOT"] = @()

    $lines = Get-Content -LiteralPath $PathValue
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -notmatch "=") {
            continue
        }

        $parts = $trimmed -split "=", 2
        $key = $parts[0].Trim().ToUpperInvariant()
        $value = $parts[1].Trim()

        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if ($key -eq "MONITOR_ROOT") {
            $rawConfig["MONITOR_ROOT"] += $value
            continue
        }

        $rawConfig[$key] = $value
    }

    $monitorRoots = @($rawConfig["MONITOR_ROOT"] | Select-Object -Unique)

    $scanInterval = 60
    if ($rawConfig.ContainsKey("SCAN_INTERVAL_SECONDS")) {
        $scanInterval = [int]$rawConfig["SCAN_INTERVAL_SECONDS"]
    }

    $quietPeriod = 600
    if ($rawConfig.ContainsKey("QUIET_PERIOD_SECONDS")) {
        $quietPeriod = [int]$rawConfig["QUIET_PERIOD_SECONDS"]
    }

    $stabilityChecks = 3
    if ($rawConfig.ContainsKey("STABILITY_CHECKS_REQUIRED")) {
        $stabilityChecks = [int]$rawConfig["STABILITY_CHECKS_REQUIRED"]
    }

    $maxItemsPerCycle = 1
    if ($rawConfig.ContainsKey("MAX_ITEMS_PER_CYCLE")) {
        $maxItemsPerCycle = [int]$rawConfig["MAX_ITEMS_PER_CYCLE"]
    }

    $seriesRegex = "^(?<Stem>.+)\\.E(?<Segment>\\d{2,3})$"
    if ($rawConfig.ContainsKey("SERIES_FILE_REGEX")) {
        $seriesRegex = $rawConfig["SERIES_FILE_REGEX"]
    }

    $stateFile = "ipedflow-state.json"
    if ($rawConfig.ContainsKey("STATE_FILE")) {
        $stateFile = $rawConfig["STATE_FILE"]
    }

    $logFile = "ipedflow.log"
    if ($rawConfig.ContainsKey("LOG_FILE")) {
        $logFile = $rawConfig["LOG_FILE"]
    }

    $ipedExecutablePath = ""
    if ($rawConfig.ContainsKey("IPED_EXECUTABLE_PATH")) {
        $ipedExecutablePath = $rawConfig["IPED_EXECUTABLE_PATH"]
    }

    $ipedDefaultProfile = "pedo"
    if ($rawConfig.ContainsKey("IPED_DEFAULT_PROFILE")) {
        $ipedDefaultProfile = $rawConfig["IPED_DEFAULT_PROFILE"]
    }

    $ipedOutputRoot = ""
    if ($rawConfig.ContainsKey("IPED_OUTPUT_ROOT")) {
        $ipedOutputRoot = $rawConfig["IPED_OUTPUT_ROOT"]
    }

    $ipedAdditionalArgs = ""
    if ($rawConfig.ContainsKey("IPED_ADDITIONAL_ARGS")) {
        $ipedAdditionalArgs = $rawConfig["IPED_ADDITIONAL_ARGS"]
    }

    return [pscustomobject]@{
        MonitorRoots = $monitorRoots
        ScanIntervalSeconds = $scanInterval
        QuietPeriodSeconds = $quietPeriod
        StabilityChecksRequired = $stabilityChecks
        MaxItemsPerCycle = $maxItemsPerCycle
        SeriesFileRegex = $seriesRegex
        StateFile = $stateFile
        LogFile = $logFile
        IPED = [pscustomobject]@{
            ExecutablePath = $ipedExecutablePath
            DefaultProfile = $ipedDefaultProfile
            OutputRoot = $ipedOutputRoot
            AdditionalArgs = $ipedAdditionalArgs
        }
    }
}

function Load-State {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        return @{ processed = @{}; pending = @{} }
    }

    try {
        $raw = Get-Content -LiteralPath $PathValue -Raw
        $data = $raw | ConvertFrom-Json -AsHashtable

        if (-not $data.ContainsKey("processed")) {
            $data["processed"] = @{}
        }

        if (-not $data.ContainsKey("pending")) {
            $data["pending"] = @{}
        }

        return $data
    }
    catch {
        return @{ processed = @{}; pending = @{} }
    }
}

function Save-State {
    param(
        [hashtable]$State,
        [string]$PathValue
    )

    $json = $State | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $PathValue -Value $json -Encoding UTF8
}

function Get-CaseDirectories {
    param([string[]]$Roots)

    $dirs = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            Write-Log -Message "Monitor root unavailable: $root" -Level "WARN"
            continue
        }

        $dirs += (Get-Item -LiteralPath $root)
        $dirs += Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
    }

    return $dirs | Select-Object -Unique
}

function Get-ExtractionCandidates {
    param(
        [string[]]$Roots,
        [pscustomobject]$Config
    )

    $regex = [regex]$Config.SeriesFileRegex
    $candidates = @()
    $caseDirs = Get-CaseDirectories -Roots $Roots

    foreach ($caseDir in $caseDirs) {
        $files = Get-ChildItem -LiteralPath $caseDir.FullName -File -ErrorAction SilentlyContinue
        if ($files.Count -eq 0) {
            continue
        }

        $series = @{}
        foreach ($file in $files) {
            $match = $regex.Match($file.Name)
            if (-not $match.Success) {
                continue
            }

            $stem = $match.Groups["Stem"].Value
            $segment = [int]$match.Groups["Segment"].Value

            if (-not $series.ContainsKey($stem)) {
                $series[$stem] = @()
            }

            $series[$stem] += [pscustomobject]@{
                Number = $segment
                Path = $file.FullName
                Length = [int64]$file.Length
                LastWriteTime = $file.LastWriteTime
            }
        }

        foreach ($stem in $series.Keys) {
            $sorted = $series[$stem] | Sort-Object Number
            $candidates += [pscustomobject]@{
                Key = "$($caseDir.FullName)|$stem|EWF"
                Root = $caseDir.Parent.FullName
                CaseDir = $caseDir.FullName
                CaseName = $caseDir.Name
                Stem = $stem
                Type = "EWF"
                Segments = $sorted
                ImagePath = $sorted[0].Path
            }
        }

        foreach ($file in $files) {
            if ($file.Extension -ine ".dd") {
                continue
            }

            $candidates += [pscustomobject]@{
                Key = "$($caseDir.FullName)|$($file.BaseName)|DD"
                Root = $caseDir.Parent.FullName
                CaseDir = $caseDir.FullName
                CaseName = $caseDir.Name
                Stem = $file.BaseName
                Type = "DD"
                Segments = @(
                    [pscustomobject]@{
                        Number = 1
                        Path = $file.FullName
                        Length = [int64]$file.Length
                        LastWriteTime = $file.LastWriteTime
                    }
                )
                ImagePath = $file.FullName
            }
        }
    }

    return $candidates
}

function Test-SeriesReady {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config
    )

    $now = Get-Date

    if ($Series.Segments.Count -eq 0) {
        return $false
    }

    foreach ($segment in $Series.Segments) {
        if ($segment.Length -le 0) {
            return $false
        }

        $ageSeconds = ($now - $segment.LastWriteTime).TotalSeconds
        if ($ageSeconds -lt $Config.QuietPeriodSeconds) {
            return $false
        }
    }

    return $true
}

function Get-SeriesFingerprint {
    param([pscustomobject]$Series)

    $count = $Series.Segments.Count
    $total = ($Series.Segments | Measure-Object -Property Length -Sum).Sum
    $last = $Series.Segments[$Series.Segments.Count - 1]

    return "$count|$total|$($last.Number)|$($last.Length)"
}

function Invoke-Iped {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config,
        [string]$Profile
    )

    $exe = $Config.IPED.ExecutablePath
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Log -Message "IPED executable not found: $exe" -Level "ERROR"
        return $false
    }

    $materialRoot = Join-Path $Config.IPED.OutputRoot $Series.CaseName
    $outputDir = Join-Path $materialRoot "IPED_processing"
    Ensure-Directory -PathValue $outputDir
    $logPath = Join-Path $outputDir "processing.log"

    $argList = @(
        "-profile", $Profile,
        "-d", $Series.ImagePath,
        "-o", $outputDir,
        "-log", $logPath
    )

    if ($Config.IPED.PSObject.Properties.Name -contains "AdditionalArgs" -and -not [string]::IsNullOrWhiteSpace($Config.IPED.AdditionalArgs)) {
        $argList += $Config.IPED.AdditionalArgs
    }

    $argsForLog = ($argList | ForEach-Object { '"' + $_ + '"' }) -join " "
    Write-Log -Message "Starting IPED for $($Series.CaseName): $exe $argsForLog"

    try {
        $process = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -eq 0) {
            Write-Log -Message "IPED completed for $($Series.CaseName)"
            return $true
        }

        Write-Log -Message "IPED failed for $($Series.CaseName) with exit code $($process.ExitCode)" -Level "ERROR"
        return $false
    }
    catch {
        Write-Log -Message "Failed to launch IPED for $($Series.CaseName): $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

$configFile = Resolve-ConfigPath -PathValue $ConfigPath
$config = Load-Config -PathValue $configFile
$monitorRoots = $config.MonitorRoots

if ($monitorRoots.Count -eq 0) {
    throw "No monitor roots configured. Check ipedflow.conf."
}

if ([string]::IsNullOrWhiteSpace($IpedProfile)) {
    $IpedProfile = $config.IPED.DefaultProfile
}

$stateFile = Resolve-ConfigPath -PathValue $config.StateFile
$script:LogFile = Resolve-ConfigPath -PathValue $config.LogFile

Ensure-ParentDirectory -PathValue $stateFile
Ensure-ParentDirectory -PathValue $script:LogFile

if (-not (Test-Path -LiteralPath $script:LogFile)) {
    New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
}

$state = Load-State -PathValue $stateFile
Write-Log -Message "IPEDflow started. Monitoring roots: $($monitorRoots -join ', ')"
Write-Log -Message "Active IPED profile: $IpedProfile"

while ($true) {
    try {
        $allSeries = Get-ExtractionCandidates -Roots $monitorRoots -Config $config | Sort-Object {
            if ($_.Segments.Count -gt 0) {
                return $_.Segments[$_.Segments.Count - 1].LastWriteTime
            }

            return [datetime]::MaxValue
        }

        $processedThisCycle = 0

        foreach ($series in $allSeries) {
            if ($processedThisCycle -ge $config.MaxItemsPerCycle) {
                break
            }

            $seriesKey = $series.Key
            $fingerprint = Get-SeriesFingerprint -Series $series

            if ($state.processed.ContainsKey($seriesKey) -and $state.processed[$seriesKey].Fingerprint -eq $fingerprint) {
                continue
            }

            if (-not (Test-SeriesReady -Series $series -Config $config)) {
                $state.pending.Remove($seriesKey) | Out-Null
                continue
            }

            if ($state.pending.ContainsKey($seriesKey) -and $state.pending[$seriesKey].Fingerprint -eq $fingerprint) {
                $stableCount = [int]$state.pending[$seriesKey].StableCount + 1
            }
            else {
                $stableCount = 1
            }

            $state.pending[$seriesKey] = @{
                Fingerprint = $fingerprint
                StableCount = $stableCount
                LastSeen = (Get-Date).ToString("o")
            }

            Write-Log -Message "Candidate ready: $($series.CaseName) [$($series.Type)] (stable check $stableCount/$($config.StabilityChecksRequired))"

            if ($stableCount -lt $config.StabilityChecksRequired) {
                continue
            }

            $ok = Invoke-Iped -Series $series -Config $config -Profile $IpedProfile
            if ($ok) {
                $state.processed[$seriesKey] = @{
                    Fingerprint = $fingerprint
                    ProcessedAt = (Get-Date).ToString("o")
                }

                $state.pending.Remove($seriesKey) | Out-Null
                $processedThisCycle += 1
            }
        }

        Save-State -State $state -PathValue $stateFile
    }
    catch {
        Write-Log -Message "Loop error: $($_.Exception.Message)" -Level "ERROR"
    }

    if ($RunOnce) {
        Write-Log -Message "RunOnce requested. Exiting."
        break
    }

    Start-Sleep -Seconds $config.ScanIntervalSeconds
}
