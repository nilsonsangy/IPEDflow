<div align="center">
	<img src="https://img.shields.io/badge/IPEDflow-Automated%20DFIR%20Queue%20Orchestration-blue?style=for-the-badge" alt="IPEDflow Badge" />
</div>

# 🚀 IPEDflow

Automated Windows monitor and service for forensic image acquisitions.

IPEDflow watches extraction folders for completed disk images in multiple formats (EWF, raw segmented, raw single-file) and triggers IPED processing automatically.


- ✅ Hands-free monitoring of acquisition folders
- ✅ **Multiple image formats**: EWF (`.E01`, `.E02`), raw segmented (`.001`, `.r00`, `.r01`, etc.), and single raw files (`.dd`, `.img`, `.raw`)
- ✅ Automatic IPED processing after image stability checks
- ✅ One case at a time to avoid overload
- ✅ Persistent state to prevent duplicate processing
- ✅ Local path settings kept out of Git

## 🧠 How IPEDflow detects readiness

A case is considered ready only when all checks pass:

- File naming matches configured patterns:
	- **EWF**: `.E01`, `.E02`, `.E03`, etc. (via `SERIES_FILE_REGEX`)
	- **Raw segmented**: `.001`, `.002`, `.r00`, `.r01`, etc. (via `RAW_FILE_REGEX`)
	- **Raw single-file**: `.dd`, `.img`, `.raw` (via `RAW_FILE_EXTENSIONS`)
- All segments have size greater than zero
- No segment has been modified during the configured quiet period
- The same fingerprint appears for the required number of stability checks
- The case has not been processed before

This strategy minimizes false positives while acquisition tools are still writing data.

## 📑 Processing order

When multiple cases are available, IPEDflow processes in this order:

- Interrupted/partial cases first (resume priority).
- Then new cases, ordered by year and material number ascending.

Example: `MAT_250_2025` is processed before `MAT_100_2026`.

## 🔁 Interrupted processing behavior

- A case is marked as completed only when IPED exits with success (`exit code 0`).
- On success, IPEDflow writes a completion marker file: `IPED_processing\.IPEDflow-completed.json`
- If output exists but the marker is missing, the case is treated as partial/interrupted.
- For partial/interrupted output, IPEDflow retries and automatically adds `--continue`.
- If processing fails, the case is kept for retry in later cycles.

## 🗂️ Configuration

Single configuration file: `IPEDflow.conf` 🔒

- This file is ignored by Git
- Create it by copying `IPEDflow.conf-example`
- The status report `IPEDflow-report.html` is also local only and is not versioned

Supported keys:

```text
MONITOR_ROOT=D:\Acquisitions\Inbox_A
MONITOR_ROOT=E:\Acquisitions\Inbox_B
MONITOR_ROOT=F:\Acquisitions\Inbox_C
IPED_EXECUTABLE_PATH=C:\Tools\IPED\iped.exe
IPED_DEFAULT_PROFILE=pedo
IPED_OUTPUT_ROOT=D:\Forensics\IPED_Processing
# Optional custom args (for example: --nogui)
IPED_ADDITIONAL_ARGS=
ENABLE_RESOURCE_LIMITS=true
MAX_CPU_PERCENT=70
MAX_MEMORY_PERCENT=70
MAX_GPU_PERCENT=80
PROCESS_PRIORITY_CLASS=BelowNormal
DETECT_GPU=true
ENABLE_STANDALONE_PROGRESS_REPORT=true
PROGRESS_REPORT_INTERVAL_MINUTES=60
SCAN_INTERVAL_SECONDS=60
QUIET_PERIOD_SECONDS=600
STABILITY_CHECKS_REQUIRED=3
MAX_ITEMS_PER_CYCLE=1
SERIES_FILE_REGEX=^(?<Stem>.+)\.E(?<Segment>\d{2,3})$
RAW_FILE_REGEX=^(?<Stem>.+)\.(?:r\d{2,3}|\d{3,})$
RAW_FILE_EXTENSIONS=.dd,.img,.raw
STATE_FILE=IPEDflow-state.json
LOG_FILE=IPEDflow.log
```

Resource control notes:

- `MAX_CPU_PERCENT` limits CPU usage in two layers: the launcher applies processor affinity to the IPED process, and it also sets `-XX:ActiveProcessorCount=<n>` so the JVM sizes its thread pools to the same CPU budget.
- When resource limits are enabled, the launcher also sets `_JAVA_OPTIONS=-XX:MaxRAMPercentage=<value> -XX:ActiveProcessorCount=<n>` for the child JVM.

How IPED is launched:

- The script starts the executable configured in `IPED_EXECUTABLE_PATH` with `Start-Process`.
- It passes these built-in arguments in this order: `-profile <profile> -d <image> -o <output> -log <processing.log>`.
- If the case is being resumed, `--continue` is appended.
- Any text in `IPED_ADDITIONAL_ARGS` is appended after the built-in arguments.
- When resource limits are enabled, the launcher also sets `_JAVA_OPTIONS=-XX:MaxRAMPercentage=<value> -XX:ActiveProcessorCount=<n>` for the child JVM.
- After launch, the script assigns the process to a Windows Job Object so the memory cap is enforced against the running process tree.

GPU notes:

- IPEDflow can detect GPUs (for example RTX cards) and log them.
- IPED/Java processing is primarily CPU-based by default.
- GPU acceleration depends on external tools/modules explicitly built for GPU usage.
- If you need a real per-process GPU throttle, you will need an external GPU-aware wrapper or vendor-specific tooling.

Atola-style case folders are supported. Example:

```text
F:\Acquisitions\Inbox_C\MAT_144_2026\MAT_144_2026.E01
F:\Acquisitions\Inbox_C\MAT_144_2026\MAT_144_2026.E02
...
```

## 📦 Output structure

For each case, IPEDflow creates:

```text
D:\Forensics\IPED_Processing\<MATERIAL>\IPED_processing
D:\Forensics\IPED_Processing\<MATERIAL>\IPED_processing\processing.log
```

## ⚡ Quick start

1. Copy example settings:

```powershell
Copy-Item .\IPEDflow.conf-example .\IPEDflow.conf
```

2. Edit `IPEDflow.conf` with your real paths and settings.

3. Run interactively:

```powershell
powershell -ExecutionPolicy Bypass -File .\IPEDflow.ps1
```

## 🧪 Useful run modes

Run once (single scan):

```powershell
powershell -ExecutionPolicy Bypass -File .\IPEDflow.ps1 -RunOnce
```

Choose an explicit profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\IPEDflow.ps1 -IPEDProfile pedo
```

## 🖥️ Standalone mode (no Windows service)

You can run IPEDflow directly without installing a service.

In standalone mode, IPEDflow can print processing percentage every hour (or your configured interval) by reading `processing.log`.

Run in foreground:

```powershell
powershell -ExecutionPolicy Bypass -File .\IPEDflow.ps1 -IPEDProfile pedo
```

Run one scan and exit:

```powershell
powershell -ExecutionPolicy Bypass -File .\IPEDflow.ps1 -RunOnce
```

Run in background (detached process):

```powershell
Start-Process -FilePath powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File .\IPEDflow.ps1 -IPEDProfile pedo' -WorkingDirectory (Get-Location)
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
powershell -ExecutionPolicy Bypass -File .\IPEDflow.ps1
```

Install and start service:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Service.ps1 -IPEDProfile pedo -StartNow
```

Uninstall service:

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-Service.ps1
```

## 🛠️ Windows service

Install and start:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Service.ps1 -StartNow
```

If the terminal is not elevated, the installer requests UAC elevation automatically.

You can pass a custom NSSM path:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Service.ps1 -NssmPath "C:\Tools\nssm\win64\nssm.exe" -StartNow
```

Install with explicit profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Service.ps1 -IPEDProfile pedo -StartNow
```

Uninstall:

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-Service.ps1
```

You can pass a custom NSSM path:

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-Service.ps1 -NssmPath "C:\Tools\nssm\win64\nssm.exe"
```

## 🔐 Security notes

- Do not commit `IPEDflow.conf`
- Keep acquisition roots and output destinations accessible by the service account
- Validate IPED executable permissions before production rollout

## 💝 Donations

If you find this project helpful and would like to support its development, consider making a donation. Your contribution helps keep this toolkit updated and motivates further improvements!

| ☕ Support this project (EN) | ☕ Apoie este projeto (PT-BR) |
|-----------------------------|------------------------------|
| If this project helps you or you think it's cool, consider supporting:<br>💳 [PayPal](https://www.paypal.com/donate/?business=7CC3CMJVYYHAC&no_recurring=0&currency_code=BRL)<br>![PayPal QR code](https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=https://www.paypal.com/donate/?business=7CC3CMJVYYHAC&no_recurring=0&currency_code=BRL) | Se este projeto te ajuda ou você acha legal, considere apoiar:<br>🇧🇷 Pix: `df92ab3c-11e2-4437-a66b-39308f794173`<br>![Pix QR code](https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=df92ab3c-11e2-4437-a66b-39308f794173) |

---
