<#
    NVIDIA SETUP SCRIPT (Run as Administrator)
#>

param (
    [int]$ForceStep = 0,    # Force execution from a specific step
    [int]$StopAfterStep = 0 # 0 = Run to end, >0 = Stop immediately after this step index
)

$Dependencies = @(
    "Utils.ps1", 
    "WindowsIds.ps1", 
    "WindowsHW.ps1", 
    "NvidiaIds.ps1", 
    "NvidiaHelpers.ps1", 
    "Networking.ps1", 
    "Logging.ps1", 
    "Wsus.ps1",
    "PidResolver.ps1")

foreach ($File in $Dependencies) {
    $FilePath = Join-Path $PSScriptRoot $File
    if (Test-Path $FilePath) {
        . $FilePath
    } else {
        Throw "Critical Error: Dependency '$File' not found at $FilePath"
    }
}

function Install-NvidiaDriverBare {
    <#
    .SYNOPSIS
        Downloads and installs a stripped-down NVIDIA driver.
        Returns $true if a new driver was actually installed, otherwise $false.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [WindowsVersionKey]$WinVer,
        [bool]$Clean = $false,
        [string]$DownloadFolder = $null
    )

    Write-Log "Nvidia Driver Setup (Bare Installation)..." -Level STEP

    # --- 1. Hardware Detection & API Check ---
    try {
        Write-Log "Checking Hardware and Requirements" -Level INFO
        $gpus = Get-HardwareByVid -Vid $GLOBAL_VID_NVIDIA

        if ($gpus.Count -eq 0) {
            Write-Log "No NVIDIA hardware detected. Skipping." -Level INFO -SubStep
            return [DriverInstallationResult]::NoInstall
        }

        $gpu = $gpus[0]
        if ($gpus.Count -gt 1) {
            Write-Log "Detected multiple NVIDIA GPUs. Using $($gpu.Caption) as primary." -Level INFO -SubStep
        }

        # Local Status & Provider Check
        $currentVersion = Format-NvidiaVersion -WmiVersion $gpu.DriverVersion
        $isNvidia = ($gpu.ProviderName -match "NVIDIA") -or 
                    ($gpu.Caption -match "NVIDIA") -or 
                    ($gpu.VideoProcessor -match "NVIDIA")

        # Remote Status Check
        $pciDetails = Get-PciRepoDeviceDetails -VendorId $gpu.VendorId -DeviceId $gpu.DeviceId
        $nvidiaDriverMeta = Get-NvidiaDriverRequestMeta -VendorId $pciDetails.VendorId -PrimaryName $pciDetails.PrimaryName
        $osId = Get-NvidiaApiOsId -WinVer $WinVer
        $latestVersion = Get-NvidiaLatestVersion -Pfid $nvidiaDriverMeta.pfid -OsId $osId

        if ($null -eq $latestVersion) {
            Write-Log "Aborting: Could not determine latest version from API." -Level ERROR
            return [DriverInstallationResult]::NoInstall
        }

        # Logic & Decision Making
        $provider = if ($isNvidia) { "NVIDIA" } else { "Microsoft/Generic/Other" }
        Write-Log "Status: [Provider: $provider] | [Installed: $currentVersion] | [Latest: $latestVersion]" -Level INFO

        # Check if already up-to-date
        if ($isNvidia -and ($currentVersion -eq $latestVersion)) {
            Write-Log "NVIDIA Driver is already up-to-date ($currentVersion)." -Level SUCCESS
            return [DriverInstallationResult]::NoInstall
        }

        # Final Action Message
        if (!$isNvidia) {
            Write-Log "Action Required: Current driver is NOT NVIDIA software. Deployment required." -Level WARN
        } else {
            Write-Log "Action Required: Update available ($currentVersion -> $latestVersion)." -Level INFO
        }
    } 
    catch {
        Write-Log "Nvidia API/Hardware check failed: $($_.Exception.Message)" -Level ERROR
        return [DriverInstallationResult]::NoInstall
    }

    # --- 2. Download & Extraction ---
    try {
        # --- STAGE 1: Environment Setup ---
        Write-Log "Preparing Installation Environment" -Level INFO
        if ([string]::IsNullOrWhiteSpace($DownloadFolder)) {
            $DownloadFolder = Join-Path $env:TEMP "NvidiaUpdate"
        }

        if (Test-Path $DownloadFolder) {
            Write-Log "Cleaning up existing download folder: $DownloadFolder" -Level INFO -SubStep
            Get-ChildItem $DownloadFolder | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "Creating download directory: $DownloadFolder" -Level INFO -SubStep
            New-Item $DownloadFolder -ItemType Directory -Force | Out-Null
        }

        $extractPath = Join-Path $DownloadFolder "Extracted"

        # --- STAGE 2: Download & Expansion ---
        $dlPath = Get-NvidiaDriverPackage -Version $latestVersion -DestinationFolder $DownloadFolder -WinVer $WinVer
        if ($null -eq $dlPath) { throw "Driver download failed." }

        # Use the helper function for clean extraction
        if (!(Expand-NvidiaDriverPackage -PackagePath $dlPath -DestinationPath $extractPath)) 
        {
            throw "Extraction process failed."
        }

        # --- 3. Deep Debloat (XML & Folder Stripping) ---
        if(!(Debloat-NvidiaDriverPackage -ExtractPath $extractPath))
        {
            Write-Log "Debloat failed. Skipping." -Level WARN
        }

        # --- 4. Installation ---
        $exitCode = Install-NvidiaDriverPackage -ExtractPath $extractPath -Clean $Clean
        $shouldReboot = $false

        if ($exitCode -eq $NVIDIA_DRIVER_SUCCESS) {
            Write-Log "NVIDIA Driver installation completed successfully." -Level SUCCESS
        }
        elseif ($exitCode -eq $NVIDIA_DRIVER_SUCCESS_REBOOT) {
            Write-Log "NVIDIA Driver installation completed successfully. (Reboot required)" -Level SUCCESS
            $shouldReboot = $true
        }
        else 
        {
            throw "NVIDIA Driver Installation failed with ExitCode: $exitCode"
        }

        # --- 5. Post-Install Cleanup ---
        Cleanup-NvidiaServices

        Write-Log "Installation process finished." -Level SUCCESS
        if($shouldReboot)
        {
            return [DriverInstallationResult]::RebootRequired
        }
        else
        {
            return [DriverInstallationResult]::Success
        }
        
    }
    catch { 
        Write-Log "Critical Error: $($_.Exception.Message)" -Level ERROR 
        return [DriverInstallationResult]::Error
    }
    finally { 
        if (Test-Path $DownloadFolder) { 
            Write-Log "Cleaning up temporary files..." -Level INFO
            Remove-Item $DownloadFolder -Recurse -Force -ErrorAction SilentlyContinue 
        } 
    }
}

function Set-WindowsGPUTweaks {
    <#
    .SYNOPSIS
        Applies OS-level GPU optimizations.
        Includes HAGS and the universal MPO disable for stability.
    #>
    Write-Log "Applying Universal Windows GPU Tweaks..." -Level STEP

    try {
        # 1. Disable Multi-Plane Overlay (MPO)
        # Universal DWM tweak. Prevents flickering/stuttering in browsers & apps.
        Write-Log "Disabling MPO (Multi-Plane Overlay)..." -Level INFO -SubStep
        $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
        if (!(Test-Path $dwmPath)) { New-Item $dwmPath -Force | Out-Null }
        Set-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -Value 5 -Type Dword

        # 2. Enable Hardware Accelerated GPU Scheduling (HAGS)
        Write-Log "Enabling HAGS..." -Level INFO -SubStep
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Force

        # 3. Disable Transparency & Game DVR
        #Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -Force
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Force
        
        Write-Log "Success: Universal GPU optimizations applied." -Level SUCCESS
    }
    catch {
        Write-Log "Failed to apply Windows GPU tweaks: $($_.Exception.Message)" -Level WARN
    }
}

function Set-NvidiaRegistryTweaks {
    <#
    .SYNOPSIS
        Applies NVIDIA-specific hardware tweaks.
    #>
    Write-Log "Applying NVIDIA-specific Hardware Tweaks..." -Level STEP

    # 1. Force Full RGB Range (0-255)
    $gpuClassPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    $instances = Get-ChildItem -Path $gpuClassPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^\d{4}$" }

    foreach ($instance in $instances) {
        Write-Log "Setting Full RGB for Instance: $($instance.PSChildName)" -Level INFO -SubStep
        Set-ItemProperty -Path $instance.PSPath -Name "VPrG_OutputRange" -Value 1 -ErrorAction SilentlyContinue
    }

    # 2. Disable NVIDIA Telemetry (If exists)
    $telemetryPath = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvTelemetry"
    if (Test-Path $telemetryPath) {
        Write-Log "Disabling Telemetry in Registry Hive..." -Level INFO -SubStep
        Set-ItemProperty -Path $telemetryPath -Name "FeatureControl" -Value 0 -Type Dword -ErrorAction SilentlyContinue
    }

    Write-Log "Success: NVIDIA-only tweaks applied." -Level SUCCESS
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

Enum DriverInstallationResult {
    Error
    NoInstall
    Success
    RebootRequired
}

Write-Log "Starting System-Level Setup" -Level STEP

Assert-Admin

# --- IMPORTANT PRE-FLIGHT NOTICE ---
Write-Host "`n"
Write-Host "****************************************************************" -ForegroundColor Yellow
Write-Host "  ATTENTION: CLEAN INSTALL RECOMMENDED" -ForegroundColor Yellow
Write-Host "  1. Uninstall old drivers (ideally using DDU)." -ForegroundColor White
Write-Host "  2. Restart your system." -ForegroundColor White
Write-Host "  3. Run this script immediately after reboot." -ForegroundColor White
Write-Host "****************************************************************" -ForegroundColor Yellow
Write-Host "`n"

if ($ForceStep -gt 0) { 
    Write-Log "Manual Override: Starting at Step $ForceStep" -Level WARN 
    Set-Step -ID $ForceStep
}

$installResult = [DriverInstallationResult]::NoInstall

# 1. Prepare Windows
if (Confirm-StepExecution "Prepare Windows" 1 $StopAfterStep) {
    Disable-AutomaticDriverInstallation
    Clear-WindowsUpdateCache
}

# 2. Hardware & Driver Setup
if (Confirm-StepExecution "Hardware & Driver Setup" 2 $StopAfterStep) {
    $winVer = Get-CurrentWindowsVersion
    $installResult = Install-NvidiaDriverBare -WinVer $winVer
    #Install-NvidiaProfileInspector
    #Install-MultiMonitorTool 
}

# 3. Final System Optimization & Performance
if (Confirm-StepExecution "Final System Optimization" 3 $StopAfterStep) {
    if ($installResult -ne [DriverInstallationResult]::NoInstall) {
        Set-WindowsGPUTweaks
        Set-NvidiaRegistryTweaks
        #Set-NvidiaProfileSettings
        #Set-MonitorLayout 
    } 
    else {
        Write-Log "Skipping Optimization: No successful driver installation detected." -Level WARN
    }
}

Remove-ProgressFile

# --- Final Result Handling ---
switch ($installResult) {
    ([DriverInstallationResult]::RebootRequired) {
        Write-Log "Nvidia Driver v$latestVersion installed. A REBOOT is required to apply all changes." -Level SUCCESS
        
        $cancelled = Wait-ForKeyOrTimeout -Timeout 30 -Message "System will RESTART in"

        if ($cancelled) {
            Write-Log "Reboot cancelled by user. Please restart manually to apply all tweaks." -Level WARN
        } else {
            Write-Log "Initiating system restart..." -Level INFO
            Restart-Computer -Force
        }
    }

    ([DriverInstallationResult]::Success) {
        Write-Log "Execution finished: Nvidia Driver v$latestVersion installed successfully. No reboot needed." -Level SUCCESS
    }

    ([DriverInstallationResult]::NoInstall) {
        Write-Log "Execution finished: Driver is already up to date or no compatible hardware found. No changes made." -Level INFO
    }

    ([DriverInstallationResult]::Error) {
        Write-Log "Execution finished with ERRORS. Please check the log for details." -Level ERROR
    }

    Default {
        Write-Log "Execution finished with an unknown result code." -Level WARN
    }
}