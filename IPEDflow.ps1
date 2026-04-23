[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$IPEDProfile,
    [switch]$RunOnce,
    [switch]$InstallService,
    [switch]$UninstallService,
    [string]$ServiceName = "IPEDflow"
)

$ErrorActionPreference = "Stop"

# --- Service Management ---
if ($InstallService) {
    Write-Host "Installing service '$ServiceName'..."
    $scriptPath = Join-Path $PSScriptRoot "scripts\Install-Service.ps1"
    & $scriptPath -ServiceName $ServiceName -ScriptPath (Join-Path $PSScriptRoot "IPEDflow.ps1") @PSBoundParameters
    exit $LASTEXITCODE
}

if ($UninstallService) {
    Write-Host "Uninstalling service '$ServiceName'..."
    $scriptPath = Join-Path $PSScriptRoot "scripts\Uninstall-Service.ps1"
    & $scriptPath -ServiceName $ServiceName @PSBoundParameters
    exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "IPEDflow.conf"
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

function Write-StandaloneProgress {
    param([string]$Message)

    if (-not $script:EnableStandaloneProgressReport) {
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp][PROGRESS] $Message"
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

function Get-IPEDProgressPercentFromLog {
    param([string]$LogPath)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return $null
    }

    try {
        $lines = Get-Content -LiteralPath $LogPath -Tail 500 -ErrorAction Stop
    }
    catch {
        return $null
    }

    $lastPercent = $null
    foreach ($line in $lines) {
        $matches = [regex]::Matches($line, "(?<!\d)(?<pct>\d{1,3})\s*%(?!\d)")
        foreach ($m in $matches) {
            $value = [int]$m.Groups["pct"].Value
            if ($value -ge 0 -and $value -le 100) {
                $lastPercent = $value
            }
        }
    }

    return $lastPercent
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

    $rawConfig = @{
        MONITOR_ROOT = @(
            "D:\Acquisitions\Inbox_A",
            "E:\Acquisitions\Inbox_B",
            "F:\Acquisitions\Inbox_C"
        )
        IPED_EXECUTABLE_PATH = "C:\Tools\IPED\iped.exe"
        IPED_DEFAULT_PROFILE = "pedo"
        IPED_OUTPUT_ROOT = "D:\Forensics\IPED_Processing"
        IPED_ADDITIONAL_ARGS = ""
        ENABLE_RESOURCE_LIMITS = "true"
        MAX_CPU_PERCENT = "70"
        MAX_MEMORY_PERCENT = "70"
        PROCESS_PRIORITY_CLASS = "BelowNormal"
        DETECT_GPU = "true"
        ENABLE_STANDALONE_PROGRESS_REPORT = "true"
        PROGRESS_REPORT_INTERVAL_MINUTES = "60"
        SCAN_INTERVAL_SECONDS = "60"
        QUIET_PERIOD_SECONDS = "600"
        STABILITY_CHECKS_REQUIRED = "3"
        MAX_ITEMS_PER_CYCLE = "1"
        SERIES_FILE_REGEX = "^(?<Stem>.+)\\.E(?<Segment>\\d{2,3})$"
        STATE_FILE = "IPEDflow-state.json"
        LOG_FILE = "IPEDflow.log"
    }

    $configSource = "defaults"
    if (Test-Path -LiteralPath $PathValue) {
        $configSource = "file"
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

        if ($rawConfig["MONITOR_ROOT"].Count -eq 0) {
            $rawConfig["MONITOR_ROOT"] = @(
                "D:\Acquisitions\Inbox_A",
                "E:\Acquisitions\Inbox_B",
                "F:\Acquisitions\Inbox_C"
            )
        }
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

    $stateFile = "IPEDflow-state.json"
    if ($rawConfig.ContainsKey("STATE_FILE")) {
        $stateFile = $rawConfig["STATE_FILE"]
    }

    $logFile = "IPEDflow.log"
    if ($rawConfig.ContainsKey("LOG_FILE")) {
        $logFile = $rawConfig["LOG_FILE"]
    }

    $IPEDExecutablePath = ""
    if ($rawConfig.ContainsKey("IPED_EXECUTABLE_PATH")) {
        $IPEDExecutablePath = $rawConfig["IPED_EXECUTABLE_PATH"]
    }

    $IPEDDefaultProfile = "pedo"
    if ($rawConfig.ContainsKey("IPED_DEFAULT_PROFILE")) {
        $IPEDDefaultProfile = $rawConfig["IPED_DEFAULT_PROFILE"]
    }

    $IPEDOutputRoot = ""
    if ($rawConfig.ContainsKey("IPED_OUTPUT_ROOT")) {
        $IPEDOutputRoot = $rawConfig["IPED_OUTPUT_ROOT"]
    }

    $IPEDAdditionalArgs = ""
    if ($rawConfig.ContainsKey("IPED_ADDITIONAL_ARGS")) {
        $IPEDAdditionalArgs = $rawConfig["IPED_ADDITIONAL_ARGS"]
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

    $enableStandaloneProgressReport = $true
    if ($rawConfig.ContainsKey("ENABLE_STANDALONE_PROGRESS_REPORT")) {
        $enableStandaloneProgressReport = Convert-ToBoolean -Value $rawConfig["ENABLE_STANDALONE_PROGRESS_REPORT"] -Default $true
    }

    $progressReportIntervalMinutes = 60
    if ($rawConfig.ContainsKey("PROGRESS_REPORT_INTERVAL_MINUTES")) {
        $progressReportIntervalMinutes = Clamp-Int -Value ([int]$rawConfig["PROGRESS_REPORT_INTERVAL_MINUTES"]) -Min 1 -Max 1440
    }

    return [pscustomobject]@{
        ConfigSource = $configSource
        MonitorRoots = $monitorRoots
        ScanIntervalSeconds = $scanInterval
        QuietPeriodSeconds = $quietPeriod
        StabilityChecksRequired = $stabilityChecks
        MaxItemsPerCycle = $maxItemsPerCycle
        SeriesFileRegex = $seriesRegex
        StateFile = $stateFile
        LogFile = $logFile
        IPED = [pscustomobject]@{
            ExecutablePath = $IPEDExecutablePath
            DefaultProfile = $IPEDDefaultProfile
            OutputRoot = $IPEDOutputRoot
            AdditionalArgs = $IPEDAdditionalArgs
        }
        Resource = [pscustomobject]@{
            EnableLimits = $enableResourceLimits
            MaxCpuPercent = $maxCpuPercent
            MaxMemoryPercent = $maxMemoryPercent
            PriorityClass = $priorityClass
            DetectGpu = $detectGpu
        }
        Progress = [pscustomobject]@{
            EnableStandaloneProgressReport = $enableStandaloneProgressReport
            ReportIntervalMinutes = $progressReportIntervalMinutes
        }
    }
}

function Load-State {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        return @{ processed = @{}; pending = @{}; failed = @{} }
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

        if (-not $data.ContainsKey("failed")) {
            $data["failed"] = @{}
        }

        return $data
    }
    catch {
        return @{ processed = @{}; pending = @{}; failed = @{} }
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

function Get-CaseOrderInfo {
    param([pscustomobject]$Series)

    $year = [int]::MaxValue
    $number = [int]::MaxValue

    $match = [regex]::Match($Series.CaseName, "(?<number>\d+)[_/-](?<year>\d{4})$")
    if ($match.Success) {
        $number = [int]$match.Groups["number"].Value
        $year = [int]$match.Groups["year"].Value
    }

    return [pscustomobject]@{
        Year = $year
        Number = $number
    }
}

function Get-IPEDPaths {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config
    )

    $materialRoot = Join-Path $Config.IPED.OutputRoot $Series.CaseName
    $outputDir = Join-Path $materialRoot "IPED_processing"
    $logPath = Join-Path $outputDir "processing.log"
    $completionMarkerPath = Join-Path $outputDir ".IPEDflow-completed.json"

    return [pscustomobject]@{
        MaterialRoot = $materialRoot
        OutputDir = $outputDir
        LogPath = $logPath
        CompletionMarkerPath = $completionMarkerPath
    }
}

function Test-IPEDCompleted {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config,
        [string]$Fingerprint
    )

    $paths = Get-IPEDPaths -Series $Series -Config $Config
    if (-not (Test-Path -LiteralPath $paths.CompletionMarkerPath)) {
        return $false
    }

    try {
        $marker = Get-Content -LiteralPath $paths.CompletionMarkerPath -Raw | ConvertFrom-Json
        if ($marker.Fingerprint -eq $Fingerprint -and $marker.Status -eq "completed") {
            return $true
        }
    }
    catch {
        return $false
    }

    return $false
}

function Test-IPEDPartialOutput {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config,
        [string]$Fingerprint
    )

    if (Test-IPEDCompleted -Series $Series -Config $Config -Fingerprint $Fingerprint) {
        return $false
    }

    $paths = Get-IPEDPaths -Series $Series -Config $Config
    if (-not (Test-Path -LiteralPath $paths.OutputDir)) {
        return $false
    }

    $content = Get-ChildItem -LiteralPath $paths.OutputDir -Force -ErrorAction SilentlyContinue
    return ($content.Count -gt 0)
}

function Write-IPEDCompletionMarker {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config,
        [string]$Fingerprint,
        [string]$Profile
    )

    $paths = Get-IPEDPaths -Series $Series -Config $Config
    Ensure-Directory -PathValue $paths.OutputDir

    $marker = [pscustomobject]@{
        Status = "completed"
        Fingerprint = $Fingerprint
        CaseName = $Series.CaseName
        Profile = $Profile
        CompletedAt = (Get-Date).ToString("o")
    }

    $marker | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $paths.CompletionMarkerPath -Encoding UTF8
}

function Invoke-IPED {
    param(
        [pscustomobject]$Series,
        [pscustomobject]$Config,
        [string]$Profile,
        [bool]$ResumeProcessing
    )

    $exe = $Config.IPED.ExecutablePath
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Log -Message "IPED executable not found: $exe" -Level "ERROR"
        return $false
    }

    $paths = Get-IPEDPaths -Series $Series -Config $Config
    Ensure-Directory -PathValue $paths.OutputDir

    $argList = @(
        "-profile", $Profile,
        "-d", $Series.ImagePath,
        "-o", $paths.OutputDir,
        "-log", $paths.LogPath
    )

    if ($ResumeProcessing) {
        $argList += "--continue"
    }

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

        $reportIntervalSeconds = [int]($Config.Progress.ReportIntervalMinutes * 60)
        $lastProgressReportAt = Get-Date

        while (-not $process.HasExited) {
            if ($script:EnableStandaloneProgressReport) {
                $elapsed = ((Get-Date) - $lastProgressReportAt).TotalSeconds
                if ($elapsed -ge $reportIntervalSeconds) {
                    $pct = Get-IPEDProgressPercentFromLog -LogPath $paths.LogPath
                    if ($null -ne $pct) {
                        Write-StandaloneProgress -Message "$($Series.CaseName): $pct% completed"
                    }
                    else {
                        Write-StandaloneProgress -Message "$($Series.CaseName): progress percentage not available yet"
                    }

                    $lastProgressReportAt = Get-Date
                }
            }

            Start-Sleep -Seconds 5
            $process.Refresh()
        }

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

function Select-NextReadySeriesKey {
    param(
        [object[]]$ReadyEntries,
        [int]$TimeoutSeconds = 10
    )

    if (-not [Environment]::UserInteractive) {
        return $null
    }

    if ($null -eq $ReadyEntries -or $ReadyEntries.Count -eq 0) {
        return $null
    }

    try {
        # Accessing Console can fail in non-interactive hosts/services.
        $null = [Console]::KeyAvailable
    }
    catch {
        return $null
    }

    Write-Host ""
    Write-Host "Manual selection window ($TimeoutSeconds seconds): choose the next ready material to process."

    for ($i = 0; $i -lt $ReadyEntries.Count; $i++) {
        $entry = $ReadyEntries[$i]
        $mode = if ($entry.InterruptedRank -eq 0) { "resume" } else { "new" }
        Write-Host ("  [{0}] {1} [{2}] ({3})" -f ($i + 1), $entry.Series.CaseName, $entry.Series.Type, $mode)
    }

    Write-Host -NoNewline ("Selection [1-{0}] then Enter (or wait for default order): " -f $ReadyEntries.Count)


    $rawInput = ""
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $userStartedTyping = $false

    while ($true) {
        if (-not $userStartedTyping -and (Get-Date) -ge $deadline) {
            break
        }
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)

            if ($key.Key -eq [ConsoleKey]::Enter) {
                break
            }

            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($rawInput.Length -gt 0) {
                    $rawInput = $rawInput.Substring(0, $rawInput.Length - 1)
                    Write-Host -NoNewline "`b `b"
                }
                continue
            }

            if ($key.KeyChar -match "\d") {
                $rawInput += $key.KeyChar
                Write-Host -NoNewline $key.KeyChar
                $userStartedTyping = $true
            }
        } else {
            Start-Sleep -Milliseconds 100
        }
    }

    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        Write-Log -Message "No manual selection received within $TimeoutSeconds seconds. Continuing by configured queue order."
        return $null
    }

    $selectedIndex = 0
    if (-not [int]::TryParse($rawInput, [ref]$selectedIndex)) {
        Write-Log -Message "Invalid manual selection '$rawInput'. Continuing by configured queue order." -Level "WARN"
        return $null
    }

    if ($selectedIndex -lt 1 -or $selectedIndex -gt $ReadyEntries.Count) {
        Write-Log -Message "Manual selection '$selectedIndex' is out of range. Continuing by configured queue order." -Level "WARN"
        return $null
    }

    $selected = $ReadyEntries[$selectedIndex - 1]
    Write-Log -Message "Manual selection received. Prioritizing: $($selected.Series.CaseName) [$($selected.Series.Type)]"
    return $selected.Series.Key
}

$configFile = Resolve-ConfigPath -PathValue $ConfigPath
$config = Load-Config -PathValue $configFile
$monitorRoots = $config.MonitorRoots

if ($monitorRoots.Count -eq 0) {
    throw "No monitor roots configured. Check IPEDflow.conf."
}

if ([string]::IsNullOrWhiteSpace($IPEDProfile)) {
    $IPEDProfile = $config.IPED.DefaultProfile
}

$stateFile = Resolve-ConfigPath -PathValue $config.StateFile
$script:LogFile = Resolve-ConfigPath -PathValue $config.LogFile

Ensure-ParentDirectory -PathValue $stateFile
Ensure-ParentDirectory -PathValue $script:LogFile

if (-not (Test-Path -LiteralPath $script:LogFile)) {
    New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
}

if ($config.ConfigSource -eq "defaults") {
    Write-Log -Message "Config file '$configFile' not found. Using built-in defaults based on IPEDflow.conf-example." -Level "WARN"
}
else {
    Write-Log -Message "Config loaded from file: $configFile"
}

$state = Load-State -PathValue $stateFile
$notifiedProcessed = @{}
$script:EnableStandaloneProgressReport = ([Environment]::UserInteractive -and $config.Progress.EnableStandaloneProgressReport)
Write-Log -Message "IPEDflow started. Monitoring roots: $($monitorRoots -join ', ')"
Write-Log -Message "Active IPED profile: $IPEDProfile"
if ($script:EnableStandaloneProgressReport) {
    Write-Log -Message "Standalone progress report enabled: every $($config.Progress.ReportIntervalMinutes) minute(s)."
}
else {
    Write-Log -Message "Standalone progress report disabled (service/non-interactive session or config disabled)."
}
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
        $processedThisCycle = 0
        # Atualiza status HTML a cada ciclo
        try {
            $statusHtmlPath = Join-Path $PSScriptRoot "IPEDflow-report.html"
            . "$PSScriptRoot\scripts\Generate-Report.ps1"
            Generate-Report -State $state -PathValue $statusHtmlPath -Config $config
        } catch { Write-Log -Message "Falha ao atualizar status HTML: $($_.Exception.Message)" -Level "WARN" }

        # --- Auditoria de recursos do sistema a cada 30 minutos ---
        if (-not $script:LastResourceAudit) {
            $script:LastResourceAudit = Get-Date
        }
        $now = Get-Date
        $minutesSinceAudit = ($now - $script:LastResourceAudit).TotalMinutes
        if ($minutesSinceAudit -ge 30) {
            # Memória
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $totalMem = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
            $freeMem = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
            $usedMem = [math]::Round($totalMem - $freeMem, 2)
            $memPct = [math]::Round(100 * $usedMem / $totalMem, 1)

            # CPU
            $cpuLoad = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
            $cpuLoad = [math]::Round($cpuLoad, 1)

            # Disco do sistema
            $sysDrive = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -eq ($os.SystemDrive + '\') })
            if ($null -eq $sysDrive) { $sysDrive = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -eq 'C' }) }
            if ($null -ne $sysDrive) {
                $diskTotal = [math]::Round($sysDrive.Used + $sysDrive.Free / 1GB, 2)
                $diskFree = [math]::Round($sysDrive.Free / 1GB, 2)
                $diskUsed = [math]::Round($sysDrive.Used / 1GB, 2)
                $diskPct = if ($diskTotal -gt 0) { [math]::Round(100 * $diskUsed / $diskTotal, 1) } else { 0 }
            } else {
                $diskTotal = $diskFree = $diskUsed = $diskPct = 'N/A'
            }

            $msg = "[AUDIT] RAM: $usedMem/$totalMem GB ($memPct%) | CPU: $cpuLoad% | Disk: $diskUsed/$diskTotal GB ($diskPct% used, $diskFree GB free)"
            Write-Log -Message $msg
            $script:LastResourceAudit = $now
        }

        while ($processedThisCycle -lt $config.MaxItemsPerCycle) {
            # Re-scan before each next material, so newly-finished extractions enter the queue immediately.
            $allSeries = Get-ExtractionCandidates -Roots $monitorRoots -Config $config

            $orderedSeries = @()
            foreach ($candidate in $allSeries) {
                $fingerprint = Get-SeriesFingerprint -Series $candidate
                $orderInfo = Get-CaseOrderInfo -Series $candidate
                $isInterrupted = Test-IPEDPartialOutput -Series $candidate -Config $config -Fingerprint $fingerprint

                $orderedSeries += [pscustomobject]@{
                    Series = $candidate
                    Fingerprint = $fingerprint
                    InterruptedRank = $(if ($isInterrupted) { 0 } else { 1 })
                    Year = $orderInfo.Year
                    Number = $orderInfo.Number
                    CaseName = $candidate.CaseName
                }
            }

            $orderedSeries = $orderedSeries | Sort-Object InterruptedRank, Year, Number, CaseName
            if ($orderedSeries.Count -eq 0) {
                break
            }

            $selectedSeriesKey = $null
            if ($orderedSeries.Count -gt 1 -and [Environment]::UserInteractive) {
                $readyEntriesForManualSelection = @()

                foreach ($entry in $orderedSeries) {
                    $series = $entry.Series
                    $seriesKey = $series.Key
                    $fingerprint = $entry.Fingerprint

                    if ($state.processed.ContainsKey($seriesKey) -and $state.processed[$seriesKey].Fingerprint -eq $fingerprint) {
                        continue
                    }

                    if (Test-IPEDCompleted -Series $series -Config $config -Fingerprint $fingerprint) {
                        continue
                    }

                    if (-not (Test-SeriesReady -Series $series -Config $config)) {
                        continue
                    }

                    $nextStableCount = 1
                    if ($state.pending.ContainsKey($seriesKey) -and $state.pending[$seriesKey].Fingerprint -eq $fingerprint) {
                        $nextStableCount = [int]$state.pending[$seriesKey].StableCount + 1
                    }

                    if ($nextStableCount -ge $config.StabilityChecksRequired) {
                        $readyEntriesForManualSelection += $entry
                    }
                }

                $selectedSeriesKey = Select-NextReadySeriesKey -ReadyEntries $readyEntriesForManualSelection -TimeoutSeconds 10

                if (-not [string]::IsNullOrWhiteSpace($selectedSeriesKey)) {
                    $selectedEntry = $orderedSeries | Where-Object { $_.Series.Key -eq $selectedSeriesKey } | Select-Object -First 1
                    if ($null -ne $selectedEntry) {
                        $remainingEntries = $orderedSeries | Where-Object { $_.Series.Key -ne $selectedSeriesKey }
                        $orderedSeries = @($selectedEntry) + @($remainingEntries)
                    }
                }
            }

            $processedOneInPass = $false

            foreach ($entry in $orderedSeries) {
                if ($processedThisCycle -ge $config.MaxItemsPerCycle) {
                    break
                }

                $series = $entry.Series
                $seriesKey = $series.Key
                $fingerprint = $entry.Fingerprint

                $resumeProcessing = $false

                if ($state.processed.ContainsKey($seriesKey) -and $state.processed[$seriesKey].Fingerprint -eq $fingerprint) {
                    if (-not $notifiedProcessed.ContainsKey($seriesKey) -or $notifiedProcessed[$seriesKey] -ne $fingerprint) {
                        Write-Log -Message "Already processed, skipping: $($series.CaseName) [$($series.Type)]"
                        $notifiedProcessed[$seriesKey] = $fingerprint
                    }

                    continue
                }

                if (Test-IPEDCompleted -Series $series -Config $config -Fingerprint $fingerprint) {
                    $state.processed[$seriesKey] = @{
                        Fingerprint = $fingerprint
                        ProcessedAt = (Get-Date).ToString("o")
                        Detection = "completion-marker"
                    }

                    Write-Log -Message "Completed marker found, marking as processed and skipping: $($series.CaseName) [$($series.Type)]"
                    $notifiedProcessed[$seriesKey] = $fingerprint
                    continue
                }

                if ($entry.InterruptedRank -eq 0) {
                    Write-Log -Message "Partial IPED output detected. Will attempt resume with --continue: $($series.CaseName) [$($series.Type)]" -Level "WARN"
                    $resumeProcessing = $true
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

                if (-not $state.pending[$seriesKey].ContainsKey("StartedAt")) {
                    $state.pending[$seriesKey].StartedAt = (Get-Date).ToString("o")
                }

                $ok = Invoke-IPED -Series $series -Config $config -Profile $IPEDProfile -ResumeProcessing $resumeProcessing
                if ($ok) {
                    $processedEntry = @{
                        Fingerprint = $fingerprint
                        ProcessedAt = (Get-Date).ToString("o")
                    }
                    if ($state.pending.ContainsKey($seriesKey) -and $state.pending[$seriesKey].ContainsKey("StartedAt")) {
                        $processedEntry.StartedAt = $state.pending[$seriesKey].StartedAt
                    }
                    $state.processed[$seriesKey] = $processedEntry

                    Write-IPEDCompletionMarker -Series $series -Config $config -Fingerprint $fingerprint -Profile $IPEDProfile

                    $state.pending.Remove($seriesKey) | Out-Null
                    $state.failed.Remove($seriesKey) | Out-Null
                    $processedThisCycle += 1
                    $processedOneInPass = $true

                    # Re-scan immediately before selecting/processing the next material.
                    break
                }
                else {
                    $failCount = 1
                    if ($state.failed.ContainsKey($seriesKey)) {
                        $failCount = [int]$state.failed[$seriesKey].Count + 1
                    }

                    $state.failed[$seriesKey] = @{
                        Count = $failCount
                        LastFailureAt = (Get-Date).ToString("o")
                        LastFingerprint = $fingerprint
                    }

                    Write-Log -Message "Case failed/interrupted and will be retried in next cycles: $($series.CaseName) [$($series.Type)] (attempt $failCount)" -Level "WARN"
                }
            }

            if (-not $processedOneInPass) {
                break
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
