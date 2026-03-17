# NVIDIA Bare-Metal Setup & System Optimizer

A PowerShell automation framework designed to deploy NVIDIA drivers without telemetry, bloatware, or background overhead. This script handles everything from Windows Update suppression to hardware-specific performance tuning.

---

## ⚠️ Critical Workflow (Do Not Skip)

For a perfect installation, you must follow the **"Clean Slate" protocol**:

1. **DDU** – Run [Display Driver Uninstaller](https://www.guru3d.com/files-details/display-driver-uninstaller-download.html) to remove existing drivers.
2. **Reboot** – Restart your PC.
3. **Run Script** – Execute this script immediately after login to prevent Windows from auto-installing a generic driver.

---

## Prerequisites & Setup

### Execution Policy

PowerShell scripts are often blocked by default. Before running the script, allow script execution in an **Administrative PowerShell session**:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
```

> **Note:** Using `-Scope Process` ensures the policy change only lasts for your current session.

### File Requirements

| File | Description |
|------|-------------|
| `Main.ps1` | The primary execution logic |
| `Utils.ps1` | Must be in the same directory (contains shared helper functions) |

---

## Features & Architecture

### 1. Dynamic Hardware & API Mapping

The script uses high-precision mapping to ensure you get the exact driver for your hardware:

- **Blackwell & Ada Support** – Full support for the latest GPU generations (RTX 50-series and 40-series).
- **PID Resolution** – Automatically translates your hardware's Device ID into the specific Product Family ID (PFID) required for the NVIDIA driver API.
- **Automated OS Resolution** – Matches your current Windows version to the correct API parameters without manual input.

### 2. "Bare" Installation Engine

Unlike standard installers, this script **strips** the driver before execution:

- **7-Zip Extraction** – Automatically downloads and uses a minimalist 7-Zip binary to unpack the installer.
- **Bloatware Removal** – Deletes `GFExperience`, `Node.js`, `NvTelemetry`, and `Update.Core` folders before setup begins to ensure they are never installed.
- **Silent Passive Install** – Uses `-passive -s -clean` flags for a non-interactive, unattended setup.
- **Service Cleanup** – Force-deletes telemetry services and scheduled tasks via `sc.exe` after the installer finishes.

### 3. Windows Update Hygiene

- **Nuclear Cache Purge** – Clears the `SoftwareDistribution\Download` folder using Robocopy mirroring — the only reliable way to bypass Windows `MAX_PATH` (260 character) errors.
- **Driver Policy Lockdown** – Configures registry keys to stop Windows Update from searching for or replacing your hardware drivers.

### 4. GPU Performance Tweaks

- **HAGS & MPO** – Enables Hardware-Accelerated GPU Scheduling and disables Multi-Plane Overlay (fixing common browser flickering).
- **Full RGB Range** – Forces the GPU class registry to use the full `0–255` color range on all displays.
- **Latency Reduction** – Disables Game DVR and desktop transparency effects for a snappier UI response.

---

## Execution & Parameters

Run **PowerShell as Administrator** and execute:

```powershell
.\NvidiaSetup.ps1
```

### Advanced Control

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `-ForceStep` | Skip directly to a specific part of the script | `-ForceStep 2` (Starts at Driver Setup) |
| `-StopAfterStep` | Stop the script after a specific phase | `-StopAfterStep 1` (Only prep Windows) |

---

## Post-Installation

Upon completion, the script will provide a **30-second countdown** before forcing a system restart. This is necessary to initialize the new driver and apply the registry-level GPU optimizations.