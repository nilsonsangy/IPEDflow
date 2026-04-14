[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$IpedProfile,
    [switch]$RunOnce
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "ipedflow.conf"
}

function Resolve-ConfigPath {
    param([string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path $PSScriptRoot $PathValue
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

function Convert-ToBoolean {
    param(
        [string]$Value,
        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "y" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "n" { return $false }
        "off" { return $false }
        default { return $Default }
    }
}

function Clamp-Int {
    param(
        [int]$Value,
        [int]$Min,
        [int]$Max
    )

    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

function Resolve-NvidiaSmiPath {
    $command = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $command = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $defaultPath = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path -LiteralPath $defaultPath) {
        return $defaultPath
    }

    return $null
}

function Get-GpuMetricsSnapshot {
    if (-not $config.Resource.GpuMetricsEnabled) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($script:NvidiaSmiPath)) {
        return @()
    }

    try {
        $metrics = & $script:NvidiaSmiPath --query-gpu=timestamp,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>$null
        if ($null -eq $metrics) {
            return @()
        }

        return @($metrics)
    }
    catch {
        return @()
    }
}

function Write-GpuMetrics {
    param([string]$Context)

    if (-not $config.Resource.GpuMetricsEnabled) {
        return
    }

    $metrics = Get-GpuMetricsSnapshot
    if ($metrics.Count -eq 0) {
        if (-not $script:GpuMetricsUnavailableLogged) {
            Write-Log -Message "GPU metrics enabled, but nvidia-smi is unavailable or returned no data." -Level "WARN"
            $script:GpuMetricsUnavailableLogged = $true
        }

        return
    }

    foreach ($line in $metrics) {
        Write-Log -Message "GPU metrics [$Context]: $line"
    }
}

function Get-AffinityMask {
    param([int]$CpuPercent)

    $logicalProcessors = [Environment]::ProcessorCount
    $targetProcessors = [int][Math]::Floor(($logicalProcessors * $CpuPercent) / 100)
    $targetProcessors = [Math]::Max(1, $targetProcessors)
    $targetProcessors = [Math]::Min($logicalProcessors, $targetProcessors)

    if ($targetProcessors -ge $logicalProcessors) {
        return [IntPtr]::Zero
    }

    [int64]$mask = 0
    for ($i = 0; $i -lt $targetProcessors; $i++) {
        $mask = $mask -bor ([int64]1 -shl $i)
    }

    return [IntPtr]$mask
}

function Apply-ProcessResourceLimits {
    param(
        [System.Diagnostics.Process]$Process,
        [pscustomobject]$Config,
        [string]$Tag
    )

    if (-not $Config.Resource.EnableLimits) {
        return
    }

    try {
        $priorityName = $Config.Resource.PriorityClass
        $valid = [System.Enum]::GetNames([System.Diagnostics.ProcessPriorityClass])
        if ($valid -contains $priorityName) {
            $Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$priorityName
        }
        else {
            $Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
            $priorityName = "BelowNormal"
        }

        $affinityMask = Get-AffinityMask -CpuPercent $Config.Resource.MaxCpuPercent
        if ($affinityMask -ne [IntPtr]::Zero) {
            $Process.ProcessorAffinity = $affinityMask
        }

        Write-Log -Message "Resource limits applied to $Tag (PID $($Process.Id)): CPU max ~$($Config.Resource.MaxCpuPercent)% | priority $priorityName"
    }
    catch {
        Write-Log -Message "Could not apply resource limits to $Tag (PID $($Process.Id)): $($_.Exception.Message)" -Level "WARN"
    }
}

function Write-GpuInfo {
    param([pscustomobject]$Config)

    if (-not $Config.Resource.DetectGpu) {
        return
    }

    try {
        $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name)
        } | Select-Object -ExpandProperty Name

        if ($null -eq $gpus -or $gpus.Count -eq 0) {
            Write-Log -Message "No GPU detected via Win32_VideoController." -Level "WARN"
            return
        }

        Write-Log -Message "GPU detected: $($gpus -join ' | ')"
        Write-Log -Message "Note: IPEDflow/IPED are primarily CPU-based. GPU acceleration depends on external tools/modules and is not enabled by default."
    }
    catch {
        Write-Log -Message "GPU detection failed: $($_.Exception.Message)" -Level "WARN"
    }
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

    $enableResourceLimits = $true
    if ($rawConfig.ContainsKey("ENABLE_RESOURCE_LIMITS")) {
        $enableResourceLimits = Convert-ToBoolean -Value $rawConfig["ENABLE_RESOURCE_LIMITS"] -Default $true
    }

    $maxCpuPercent = 70
    if ($rawConfig.ContainsKey("MAX_CPU_PERCENT")) {
        $maxCpuPercent = Clamp-Int -Value ([int]$rawConfig["MAX_CPU_PERCENT"]) -Min 1 -Max 100
    }

    $maxMemoryPercent = 70
    if ($rawConfig.ContainsKey("MAX_MEMORY_PERCENT")) {
        $maxMemoryPercent = Clamp-Int -Value ([int]$rawConfig["MAX_MEMORY_PERCENT"]) -Min 1 -Max 100
    }

    $priorityClass = "BelowNormal"
    if ($rawConfig.ContainsKey("PROCESS_PRIORITY_CLASS")) {
        $priorityClass = $rawConfig["PROCESS_PRIORITY_CLASS"]
    }

    $detectGpu = $true
    if ($rawConfig.ContainsKey("DETECT_GPU")) {
        $detectGpu = Convert-ToBoolean -Value $rawConfig["DETECT_GPU"] -Default $true
    }

    $gpuMetricsEnabled = $false
    if ($rawConfig.ContainsKey("GPU_METRICS_ENABLED")) {
        $gpuMetricsEnabled = Convert-ToBoolean -Value $rawConfig["GPU_METRICS_ENABLED"] -Default $true
    }

    $gpuMetricsIntervalActiveSeconds = 30
    if ($rawConfig.ContainsKey("GPU_METRICS_INTERVAL_ACTIVE_SECONDS")) {
        $gpuMetricsIntervalActiveSeconds = Clamp-Int -Value ([int]$rawConfig["GPU_METRICS_INTERVAL_ACTIVE_SECONDS"]) -Min 5 -Max 3600
    }

    $gpuMetricsIntervalIdleSeconds = 300
    if ($rawConfig.ContainsKey("GPU_METRICS_INTERVAL_IDLE_SECONDS")) {
        $gpuMetricsIntervalIdleSeconds = Clamp-Int -Value ([int]$rawConfig["GPU_METRICS_INTERVAL_IDLE_SECONDS"]) -Min 30 -Max 3600
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
        Resource = [pscustomobject]@{
            EnableLimits = $enableResourceLimits
            MaxCpuPercent = $maxCpuPercent
            MaxMemoryPercent = $maxMemoryPercent
            PriorityClass = $priorityClass
            DetectGpu = $detectGpu
            GpuMetricsEnabled = $gpuMetricsEnabled
            GpuMetricsIntervalActiveSeconds = $gpuMetricsIntervalActiveSeconds
            GpuMetricsIntervalIdleSeconds = $gpuMetricsIntervalIdleSeconds
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

function Test-IpedOutputAlreadyExists {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config
    )

    $materialRoot = Join-Path $Config.IPED.OutputRoot $Series.CaseName
    $outputDir = Join-Path $materialRoot "IPED_processing"
    $logPath = Join-Path $outputDir "processing.log"

    if (Test-Path -LiteralPath $logPath) {
        return $true
    }

    if (Test-Path -LiteralPath $outputDir) {
        $content = Get-ChildItem -LiteralPath $outputDir -Force -ErrorAction SilentlyContinue
        if ($content.Count -gt 0) {
            return $true
        }
    }

    return $false
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

    $previousJavaOptions = $env:_JAVA_OPTIONS
    if ($Config.Resource.EnableLimits) {
        $maxRamOption = "-XX:MaxRAMPercentage=$($Config.Resource.MaxMemoryPercent)"
        if ([string]::IsNullOrWhiteSpace($previousJavaOptions)) {
            $env:_JAVA_OPTIONS = $maxRamOption
        }
        elseif ($previousJavaOptions -match "MaxRAMPercentage") {
            $env:_JAVA_OPTIONS = [regex]::Replace($previousJavaOptions, "-XX:MaxRAMPercentage=\S+", $maxRamOption)
        }
        else {
            $env:_JAVA_OPTIONS = "$previousJavaOptions $maxRamOption"
        }

        Write-Log -Message "Applied JVM memory cap hint: $maxRamOption"
    }

    try {
        $process = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden
        Apply-ProcessResourceLimits -Process $process -Config $Config -Tag "IPED"
        Write-GpuMetrics -Context "process-start:$($Series.CaseName)"

        $lastActiveGpuMetricAt = Get-Date
        while (-not $process.HasExited) {
            $process.Refresh()

            if ($Config.Resource.GpuMetricsEnabled) {
                $elapsed = ((Get-Date) - $lastActiveGpuMetricAt).TotalSeconds
                if ($elapsed -ge $Config.Resource.GpuMetricsIntervalActiveSeconds) {
                    Write-GpuMetrics -Context "processing:$($Series.CaseName)"
                    $lastActiveGpuMetricAt = Get-Date
                }
            }

            Start-Sleep -Seconds 1
        }

        Write-GpuMetrics -Context "process-end:$($Series.CaseName)"
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
    finally {
        $env:_JAVA_OPTIONS = $previousJavaOptions
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
$notifiedProcessed = @{}
$script:NvidiaSmiPath = Resolve-NvidiaSmiPath
$script:GpuMetricsUnavailableLogged = $false
$script:LastIdleGpuMetricsAt = (Get-Date).AddSeconds(-$config.Resource.GpuMetricsIntervalIdleSeconds)
Write-Log -Message "IPEDflow started. Monitoring roots: $($monitorRoots -join ', ')"
Write-Log -Message "Active IPED profile: $IpedProfile"
if ($config.Resource.EnableLimits) {
    Write-Log -Message "Resource limits enabled: CPU=$($config.Resource.MaxCpuPercent)% | Memory/JVM=$($config.Resource.MaxMemoryPercent)% | Priority=$($config.Resource.PriorityClass)"
}
else {
    Write-Log -Message "Resource limits disabled by configuration."
}

Apply-ProcessResourceLimits -Process (Get-Process -Id $PID) -Config $config -Tag "IPEDflow"
Write-GpuInfo -Config $config

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
                if (-not $notifiedProcessed.ContainsKey($seriesKey) -or $notifiedProcessed[$seriesKey] -ne $fingerprint) {
                    Write-Log -Message "Already processed, skipping: $($series.CaseName) [$($series.Type)]"
                    $notifiedProcessed[$seriesKey] = $fingerprint
                }

                continue
            }

            if (Test-IpedOutputAlreadyExists -Series $series -Config $config) {
                $state.processed[$seriesKey] = @{
                    Fingerprint = $fingerprint
                    ProcessedAt = (Get-Date).ToString("o")
                    Detection = "existing-output"
                }

                Write-Log -Message "Existing IPED output detected, marking as processed and skipping: $($series.CaseName) [$($series.Type)]"
                $notifiedProcessed[$seriesKey] = $fingerprint
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

        if ($config.Resource.GpuMetricsEnabled) {
            $idleElapsed = ((Get-Date) - $script:LastIdleGpuMetricsAt).TotalSeconds
            if ($idleElapsed -ge $config.Resource.GpuMetricsIntervalIdleSeconds) {
                Write-GpuMetrics -Context "idle"
                $script:LastIdleGpuMetricsAt = Get-Date
            }
        }
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
