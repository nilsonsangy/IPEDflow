# IPEDflow 🚀

Automated Windows service monitor for forensic image acquisitions.

IPEDflow watches extraction folders for completed disk images (`.E01`, `.E02`, ... or `.dd`) and triggers IPED processing automatically.

## ✨ Why IPEDflow

- ✅ Hands-free monitoring of acquisition folders
- ✅ Automatic IPED processing after image stability checks
- ✅ One case at a time to avoid overload
- ✅ Persistent state to prevent duplicate processing
- ✅ Local path settings kept out of Git

## 🧠 How readiness is detected

A case is considered ready only when all checks pass:

- File naming matches the configured EWF regex, or a `.dd` file is found
- All segments have size greater than zero
- No segment has been modified during the configured quiet period
- The same fingerprint appears for the required number of stability checks
- The case has not been processed before

This strategy minimizes false positives while acquisition is still writing data.

## 🗂️ Configuration

Single configuration file: `ipedflow.conf` 🔒

- This file is ignored by Git
- Create it by copying `ipedflow.example.conf`

Supported keys:

```text
MONITOR_ROOT=D:\Acquisitions\Inbox_A
MONITOR_ROOT=E:\Acquisitions\Inbox_B
MONITOR_ROOT=F:\Acquisitions\Inbox_C
IPED_EXECUTABLE_PATH=C:\Tools\IPED\iped.exe
IPED_DEFAULT_PROFILE=pedo
IPED_OUTPUT_ROOT=D:\Forensics\IPED_Processing
IPED_ADDITIONAL_ARGS=
SCAN_INTERVAL_SECONDS=60
QUIET_PERIOD_SECONDS=600
STABILITY_CHECKS_REQUIRED=3
MAX_ITEMS_PER_CYCLE=1
SERIES_FILE_REGEX=^(?<Stem>.+)\.E(?<Segment>\d{2,3})$
STATE_FILE=ipedflow-state.json
LOG_FILE=ipedflow.log
```

Atola-style case folders are supported, for example:

```text
F:\Acquisitions\Inbox_C\MAT_144_2026\MAT_144_2026.E01
F:\Acquisitions\Inbox_C\MAT_144_2026\MAT_144_2026.E02
...
```

## 📦 Output structure

For each case, IPEDflow creates:

```text
D:\Forensics\IPED_Processing\\<MATERIAL>\IPED_processing
D:\Forensics\IPED_Processing\\<MATERIAL>\IPED_processing\processing.log
```

## ⚡ Quick start

1. Copy example settings:

```powershell
Copy-Item .\ipedflow.example.conf .\ipedflow.conf
```

2. Edit `ipedflow.conf` with your real paths and settings.

3. Run interactively:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\IPEDflow.ps1
```

## 🧪 Useful run modes

Run once (single scan):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\IPEDflow.ps1 -RunOnce
```

Choose profile explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\IPEDflow.ps1 -IpedProfile pedo
```

## 🧩 Prerequisite

Install NSSM (Non-Sucking Service Manager) and keep `nssm.exe` in your PATH,
or provide it explicitly with `-NssmPath` in install/uninstall commands.

Install via winget (recommended):

```powershell
winget install --id NSSM.NSSM -e
nssm version
```

## 🧾 Command reference

Run script:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\IPEDflow.ps1
```

Install and start service:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-IPEDflowService.ps1 -IpedProfile pedo -StartNow
```

Uninstall service:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-IPEDflowService.ps1
```

## 🛠️ Windows service

Install and start:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-IPEDflowService.ps1 -StartNow
```

If the terminal is not elevated, the installer requests UAC elevation automatically.

You can pass a custom NSSM path:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-IPEDflowService.ps1 -NssmPath "C:\Tools\nssm\win64\nssm.exe" -StartNow
```

Install with explicit profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-IPEDflowService.ps1 -IpedProfile pedo -StartNow
```

Uninstall:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-IPEDflowService.ps1
```

You can pass a custom NSSM path:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-IPEDflowService.ps1 -NssmPath "C:\Tools\nssm\win64\nssm.exe"
```

## 🔐 Security notes

- Do not commit `ipedflow.conf`
- Keep acquisition roots and output destinations accessible by the service account
- Validate IPED executable permissions before production rollout
