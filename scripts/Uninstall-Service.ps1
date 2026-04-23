[CmdletBinding()]
param(
    [string]$ServiceName = "IPEDflow",
    [string]$NssmPath = "nssm"
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
        "-NssmPath", "`"$NssmPath`""
    )

    try {
        $elevated = Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $arguments -PassThru
        Write-Host "Elevation requested. Approve the UAC prompt to continue uninstallation."
        $elevated.WaitForExit()
    }
    catch {
        throw "Administrator privileges are required. UAC elevation was canceled or failed. Details: $($_.Exception.Message)"
    }

    $serviceAfterElevation = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $serviceAfterElevation) {
        throw "Service removal did not complete successfully. Service '$ServiceName' still exists."
    }

    Write-Host "Service removed: $ServiceName"
    exit 0
}

$resolvedNssmPath = Resolve-NssmExecutable -Candidate $NssmPath

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Write-Host "Service not found: $ServiceName"
    exit 0
}

if ($service.Status -ne "Stopped") {
    & $resolvedNssmPath stop $ServiceName | Out-Null
}

& $resolvedNssmPath remove $ServiceName confirm | Out-Null

$removed = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -ne $removed) {
    throw "Service removal failed: $ServiceName still exists."
}

Write-Host "Service removed: $ServiceName"
