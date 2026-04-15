[CmdletBinding()]
param(
    [string]$ServiceName = "IPEDflow",
    [string]$DisplayName = "IPEDflow Monitor Service",
    [string]$Description = "Monitors extraction folders and triggers IPED processing.",
    [string]$ScriptPath,
    [string]$ConfigPath,
    [string]$IPEDProfile = "pedo",
    [string]$NssmPath = "nssm",
    [switch]$StartNow
)

$ErrorActionPreference = "Stop"

function Resolve-NssmExecutable {
    param([string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        $Candidate = "nssm"
    }

    if ([System.IO.Path]::IsPathRooted($Candidate)) {
        if (-not (Test-Path -LiteralPath $Candidate)) {
            throw "NSSM executable not found: $Candidate"
        }

        return $Candidate
    }

    $command = Get-Command $Candidate -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $command = Get-Command "nssm.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw "NSSM was not found in PATH. Install NSSM and rerun, or pass -NssmPath with the full path to nssm.exe."
}

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $PSScriptRoot "IPEDflow.ps1"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "IPEDflow.conf"
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-ServiceName", "`"$ServiceName`"",
        "-DisplayName", "`"$DisplayName`"",
        "-Description", "`"$Description`"",
        "-ScriptPath", "`"$ScriptPath`"",
        "-ConfigPath", "`"$ConfigPath`"",
        "-IPEDProfile", "`"$IPEDProfile`"",
        "-NssmPath", "`"$NssmPath`""
    )

    if ($StartNow) {
        $arguments += "-StartNow"
    }

    try {
        $elevated = Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $arguments -PassThru
        Write-Host "Elevation requested. Approve the UAC prompt to continue installation."
        $elevated.WaitForExit()
    }
    catch {
        throw "Administrator privileges are required. UAC elevation was canceled or failed. Details: $($_.Exception.Message)"
    }

    $serviceAfterElevation = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $serviceAfterElevation) {
        throw "Installation did not complete successfully. Service '$ServiceName' was not found."
    }

    if ($StartNow -and $serviceAfterElevation.Status -ne "Running") {
        throw "Installation completed, but service '$ServiceName' is not running. Current state: $($serviceAfterElevation.Status)"
    }

    if ($StartNow) {
        Write-Host "Service installed and running: $ServiceName"
    }
    else {
        Write-Host "Service installed: $ServiceName"
    }

    exit 0
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    throw "Service already exists: $ServiceName"
}

$resolvedNssmPath = Resolve-NssmExecutable -Candidate $NssmPath
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$serviceArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -IPEDProfile `"$IPEDProfile`""

& $resolvedNssmPath install $ServiceName $psExe $serviceArguments | Out-Null
& $resolvedNssmPath set $ServiceName DisplayName $DisplayName | Out-Null
& $resolvedNssmPath set $ServiceName Description $Description | Out-Null
& $resolvedNssmPath set $ServiceName Start SERVICE_AUTO_START | Out-Null

$installed = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $installed) {
    throw "Service installation failed: $ServiceName was not found after NSSM install."
}

Write-Host "Service installed: $ServiceName"

if ($StartNow) {
    & $resolvedNssmPath start $ServiceName | Out-Null
    $started = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($started.Status -ne "Running") {
        throw "Service start command completed, but service is not running. Current state: $($started.Status)"
    }

    Write-Host "Service started: $ServiceName"
}
